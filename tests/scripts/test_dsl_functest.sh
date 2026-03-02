#!/bin/bash
# Functional + safety tests for DSL-based device matching in MicroCeph.
#
# Focus areas:
#  - DSL expression matching/validation
#  - WAL/DB partition planning safety guarantees (overlap + capacity checks)
#  - WAL/DB assignment correctness after actual OSD add

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIONUTILS_SCRIPT="${SCRIPT_DIR}/actionutils.sh"
# shellcheck source=/dev/null
source "${ACTIONUTILS_SCRIPT}"

# Configuration
VM_NAME="${VM_NAME:-microceph-dsl-test}"
PROFILE="${PROFILE:-default}"
CORES="${CORES:-2}"
MEM="${MEM:-4GiB}"
STORAGE_POOL="${STORAGE_POOL:-default}"
SNAP_PATH="${SNAP_PATH:-}" # Path to local snap file, empty means use store
SNAP_CHANNEL="${SNAP_CHANNEL:-latest/edge}"
NO_CLEANUP="${NO_CLEANUP:-0}"
SETUP_LXD="${SETUP_LXD:-0}" # If 1, reuse actionutils.sh setup_lxd()

# Disk configurations: name:size pairs
DISK1_NAME="${VM_NAME}-disk1"
DISK1_SIZE="${DISK1_SIZE:-4GiB}"
DISK2_NAME="${VM_NAME}-disk2"
DISK2_SIZE="${DISK2_SIZE:-2GiB}"
DISK3_NAME="${VM_NAME}-disk3"
DISK3_SIZE="${DISK3_SIZE:-2GiB}"
DISK4_NAME="${VM_NAME}-disk4"
DISK4_SIZE="${DISK4_SIZE:-4GiB}"
DISK5_NAME="${VM_NAME}-disk5"
DISK5_SIZE="${DISK5_SIZE:-4GiB}"
DISK6_NAME="${VM_NAME}-disk6"
DISK6_SIZE="${DISK6_SIZE:-4GiB}"

CONTROL_SOCKET="/var/snap/microceph/common/state/control.socket"
ONE_GIB_BYTES=1073741824
SIZE_TOLERANCE_BYTES=2097152 # 2 MiB
SENTINEL_PART_SIZE_SGDISK="64M"
SMALL_WALDB_PART_SIZE="128MiB"

# Selected test disks (resolved during setup)
OSD_DISK_PRIMARY=""
OSD_DISK_SECONDARY=""
OSD_DISK_TERTIARY=""
OSD_DISK_QUATERNARY=""
WAL_DISK=""
DB_DISK=""
OSD_DEV_PRIMARY=""
OSD_DEV_SECONDARY=""
OSD_DEV_TERTIARY=""
OSD_DEV_QUATERNARY=""
WAL_DEVNODE=""
DB_DEVNODE=""

function info() {
    echo "[INFO] $*"
}

function pass() {
    echo "[PASS] $*"
}

function fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

function assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Expected output to contain '${needle}'}"
    if ! grep -Fq -- "$needle" <<<"$haystack"; then
        fail "$message"
    fi
}

function assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Expected output to NOT contain '${needle}'}"
    if grep -Fq -- "$needle" <<<"$haystack"; then
        fail "$message"
    fi
}

function assert_regex() {
    local haystack="$1"
    local regex="$2"
    local message="${3:-Expected output to match regex '${regex}'}"
    if ! grep -Eq -- "$regex" <<<"$haystack"; then
        fail "$message"
    fi
}

function assert_eq() {
    local got="$1"
    local expected="$2"
    local message="${3:-Expected '${expected}', got '${got}'}"
    if [[ "$got" != "$expected" ]]; then
        fail "$message"
    fi
}

function assert_ne() {
    local got="$1"
    local expected="$2"
    local message="${3:-Expected '${got}' to differ from '${expected}'}"
    if [[ "$got" == "$expected" ]]; then
        fail "$message"
    fi
}

function assert_ge() {
    local got="$1"
    local minimum="$2"
    local message="${3:-Expected '${got}' >= '${minimum}'}"
    if (( got < minimum )); then
        fail "$message"
    fi
}

function assert_size_close() {
    local actual="$1"
    local expected="$2"
    local tolerance="$3"
    local what="$4"

    local diff=$(( actual - expected ))
    if (( diff < 0 )); then
        diff=$(( -diff ))
    fi

    if (( diff > tolerance )); then
        fail "${what}: expected ~${expected} bytes (±${tolerance}), got ${actual}"
    fi
}

# Run command in VM
function vm_exec() {
    lxc exec "$VM_NAME" -- "$@"
}

# Run shell command in VM
function vm_sh() {
    local cmd="$1"
    lxc exec "$VM_NAME" -- bash -lc "$cmd"
}

# Run shell command in VM and capture output; return command exit code.
# This helper intentionally drops `set -e` while the command runs so tests can
# assert on expected failures without aborting the entire test script.
# Usage:
#   if run_vm_capture out "my command"; then ...; fi
function run_vm_capture() {
    local __out_var="$1"
    local cmd="$2"

    local _captured_output
    local rc

    set +e
    _captured_output=$(vm_sh "$cmd" 2>&1)
    rc=$?
    set -e

    printf -v "$__out_var" '%s' "$_captured_output"
    return "$rc"
}

# POST /1.0/disks inside VM and return raw JSON response.
function vm_post_disks() {
    local payload="$1"
    vm_exec curl --silent --show-error --unix-socket "$CONTROL_SOCKET" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$payload" \
        http://localhost/1.0/disks
}

function get_configured_count() {
    vm_sh "microceph disk list --json | jq -r '.ConfiguredDisks | length'"
}

function wait_for_configured_count() {
    local expected="$1"
    local timeout="${2:-120}"
    local elapsed=0

    while (( elapsed < timeout )); do
        local current
        current=$(get_configured_count)
        if (( current >= expected )); then
            pass "Configured disks reached ${current} (expected >= ${expected})"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    fail "Timed out waiting for configured disks >= ${expected}"
}

function partition_count() {
    local devnode="$1"
    vm_sh "lsblk -nr -o NAME '${devnode}' | tail -n +2 | grep -c . || true"
}

function first_partition_path() {
    local devnode="$1"
    vm_sh "lsblk -nr -o PATH '${devnode}' | tail -n +2 | head -n1"
}

function partition_path_by_number() {
    local devnode="$1"
    local part_num="$2"
    local fallback_path
    local detected_path

    # Partition naming differs by device type:
    #   /dev/sdX   -> /dev/sdX1
    #   /dev/nvme0n1 -> /dev/nvme0n1p1
    # Build a best-effort fallback path, but prefer lsblk+PARTN when possible.
    if [[ "$devnode" =~ [0-9]$ ]]; then
        fallback_path="${devnode}p${part_num}"
    else
        fallback_path="${devnode}${part_num}"
    fi

    # Kernel partition table updates can lag behind sgdisk writes in VMs.
    # Retry with partprobe/partx + udev settle before giving up.
    for _ in $(seq 1 20); do
        detected_path=$(vm_sh "lsblk -nr -o PATH,PARTN '${devnode}' | awk '\$2 == \"${part_num}\" {print \$1; exit}'")
        if [[ -n "$detected_path" ]]; then
            echo "$detected_path"
            return 0
        fi

        if vm_sh "test -b '${fallback_path}'"; then
            echo "$fallback_path"
            return 0
        fi

        vm_sh "partprobe '${devnode}' >/dev/null 2>&1 || partx -u '${devnode}' >/dev/null 2>&1 || true"
        vm_sh "udevadm settle || true"
        sleep 1
    done

    echo ""
}

function block_size_bytes() {
    local path="$1"
    vm_sh "lsblk -bnr -o SIZE '${path}'"
}

function get_osd_dir_for_disk_path() {
    local disk_path="$1"
    local osd_id
    osd_id=$(vm_sh "microceph disk list --json | jq -r --arg p '${disk_path}' '.ConfiguredDisks[] | select(.path == \$p) | .osd' | head -n1")
    if [[ -z "$osd_id" || "$osd_id" == "null" ]]; then
        fail "Could not resolve OSD id for disk path '${disk_path}'"
    fi
    echo "/var/snap/microceph/common/data/osd/ceph-${osd_id}"
}

# Cleanup function
function cleanup_dsl_test() {
    local exit_code=$?
    info "Cleaning up..."

    lxc stop "$VM_NAME" --force 2>/dev/null || true
    lxc delete "$VM_NAME" --force 2>/dev/null || true

    for disk in "$DISK1_NAME" "$DISK2_NAME" "$DISK3_NAME" "$DISK4_NAME" "$DISK5_NAME" "$DISK6_NAME"; do
        lxc storage volume delete "$STORAGE_POOL" "$disk" 2>/dev/null || true
    done

    if [ "$exit_code" -eq 0 ]; then
        pass "DSL functional test completed successfully"
    else
        echo "[FAIL] DSL functional test failed with exit code ${exit_code}" >&2
    fi

    exit "$exit_code"
}

# Wait for VM to be ready
function wait_for_dsl_vm() {
    local name="$1"
    local timeout="${2:-300}"
    local elapsed=0

    info "Waiting for VM '${name}' to be ready (timeout: ${timeout}s)..."

    while (( elapsed < timeout )); do
        if lxc exec "$name" -- cloud-init status --wait 2>/dev/null | grep -q "done"; then
            pass "VM '${name}' is ready"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done

    echo ""
    fail "Timeout waiting for VM '${name}' to be ready"
}

# Disable multipath in VM (LXD disks share WWIDs and get grouped as multipath members)
function disable_multipath_in_vm() {
    info "Disabling multipathd in VM..."
    vm_sh "systemctl stop multipathd multipathd.socket || true"
    vm_sh "systemctl disable multipathd multipathd.socket || true"
    vm_sh "systemctl mask multipathd multipathd.socket || true"
    vm_sh "multipath -F || true"
    vm_sh "udevadm settle || true"
}

function ensure_host_prereqs() {
    if [[ "$SETUP_LXD" -eq 1 ]]; then
        info "Running actionutils.setup_lxd()"
        setup_lxd
    fi

    if ! command -v jq >/dev/null 2>&1; then
        info "Installing jq on host"
        sudo apt-get update -qq
        sudo apt-get install -y jq >/dev/null
    fi
}

# Setup DSL test environment
function setup_dsl_test() {
    set -eux

    ensure_host_prereqs

    echo "=== MicroCeph DSL Functional Test ==="
    echo "VM Name: $VM_NAME"
    echo "Disks:"
    echo "  - $DISK1_NAME ($DISK1_SIZE)"
    echo "  - $DISK2_NAME ($DISK2_SIZE)"
    echo "  - $DISK3_NAME ($DISK3_SIZE)"
    echo "  - $DISK4_NAME ($DISK4_SIZE)"
    echo "  - $DISK5_NAME ($DISK5_SIZE)"
    echo "  - $DISK6_NAME ($DISK6_SIZE)"

    if lxc info "$VM_NAME" &>/dev/null; then
        lxc stop "$VM_NAME" --force 2>/dev/null || true
        lxc delete "$VM_NAME" --force 2>/dev/null || true
    fi

    for disk in "$DISK1_NAME" "$DISK2_NAME" "$DISK3_NAME" "$DISK4_NAME" "$DISK5_NAME" "$DISK6_NAME"; do
        if lxc storage volume show "$STORAGE_POOL" "$disk" &>/dev/null; then
            lxc storage volume delete "$STORAGE_POOL" "$disk" 2>/dev/null || true
        fi
    done

    lxc storage volume create "$STORAGE_POOL" "$DISK1_NAME" --type block size="$DISK1_SIZE"
    lxc storage volume create "$STORAGE_POOL" "$DISK2_NAME" --type block size="$DISK2_SIZE"
    lxc storage volume create "$STORAGE_POOL" "$DISK3_NAME" --type block size="$DISK3_SIZE"
    lxc storage volume create "$STORAGE_POOL" "$DISK4_NAME" --type block size="$DISK4_SIZE"
    lxc storage volume create "$STORAGE_POOL" "$DISK5_NAME" --type block size="$DISK5_SIZE"
    lxc storage volume create "$STORAGE_POOL" "$DISK6_NAME" --type block size="$DISK6_SIZE"

    lxc launch ubuntu:24.04 "$VM_NAME" \
        -p "$PROFILE" \
        -c limits.cpu="$CORES" \
        -c limits.memory="$MEM" \
        --vm

    lxc storage volume attach "$STORAGE_POOL" "$DISK1_NAME" "$VM_NAME"
    lxc storage volume attach "$STORAGE_POOL" "$DISK2_NAME" "$VM_NAME"
    lxc storage volume attach "$STORAGE_POOL" "$DISK3_NAME" "$VM_NAME"
    lxc storage volume attach "$STORAGE_POOL" "$DISK4_NAME" "$VM_NAME"
    lxc storage volume attach "$STORAGE_POOL" "$DISK5_NAME" "$VM_NAME"
    lxc storage volume attach "$STORAGE_POOL" "$DISK6_NAME" "$VM_NAME"

    wait_for_dsl_vm "$VM_NAME"
    disable_multipath_in_vm

    # Allow udev to settle for newly attached block devices.
    sleep 5
}

# Resolve snap path glob pattern to actual file
function resolve_snap_path() {
    local pattern="$1"
    local resolved

    resolved=$(compgen -G "$pattern" | head -n1 || true)

    if [ -n "$resolved" ] && [ -f "$resolved" ]; then
        echo "$resolved"
        return 0
    fi
    return 1
}

function install_vm_test_tools() {
    info "Installing VM test dependencies (jq, curl, gdisk)"
    vm_sh "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
    vm_sh "DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl gdisk >/dev/null"
    vm_sh "command -v sgdisk >/dev/null"
}

# Install MicroCeph snap in VM
function install_microceph_in_vm() {
    set -eux

    local snap_file=""
    if [ -n "$SNAP_PATH" ]; then
        snap_file=$(resolve_snap_path "$SNAP_PATH") || true
    fi

    if [ -n "$snap_file" ] && [ -f "$snap_file" ]; then
        info "Installing from local snap: $snap_file"
        lxc file push "$snap_file" "$VM_NAME/tmp/microceph.snap"
        vm_exec snap install /tmp/microceph.snap --dangerous

        vm_exec snap connect microceph:block-devices || true
        vm_exec snap connect microceph:hardware-observe || true
        vm_exec snap connect microceph:mount-observe || true
        vm_exec snap connect microceph:dm-crypt || true
        vm_exec snap connect microceph:microceph-support || true
        vm_exec snap connect microceph:network-bind || true
        vm_exec snap connect microceph:process-control || true
    else
        if [ -n "$SNAP_PATH" ]; then
            info "No snap file found matching '$SNAP_PATH', falling back to snap store"
        fi
        info "Installing from snap store channel: $SNAP_CHANNEL"
        vm_exec snap install microceph --channel="$SNAP_CHANNEL"
    fi

    install_vm_test_tools

    info "Bootstrapping MicroCeph cluster"
    vm_exec microceph cluster bootstrap

    # Ensure cluster responds and control socket is available.
    vm_exec microceph.ceph version
    vm_exec microceph.ceph -s
    vm_sh "test -S '$CONTROL_SOCKET'"
}

function select_test_disks() {
    local disk_list_json
    disk_list_json=$(vm_exec microceph disk list --json)

    local available_count
    available_count=$(jq -r '.AvailableDisks | length' <<<"$disk_list_json")
    assert_ge "$available_count" 6 "Expected at least 6 available disks before tests"

    mapfile -t four_gib_disks < <(jq -r '.AvailableDisks[] | select(.Size == "4.00GiB") | .Path' <<<"$disk_list_json" | sort)
    mapfile -t two_gib_disks < <(jq -r '.AvailableDisks[] | select(.Size == "2.00GiB") | .Path' <<<"$disk_list_json" | sort)

    if (( ${#four_gib_disks[@]} < 4 )); then
        fail "Need at least four 4.00GiB disks for OSD tests (found ${#four_gib_disks[@]})"
    fi

    if (( ${#two_gib_disks[@]} < 2 )); then
        fail "Need at least two 2.00GiB disks for WAL/DB tests (found ${#two_gib_disks[@]})"
    fi

    OSD_DISK_PRIMARY="${four_gib_disks[0]}"
    OSD_DISK_SECONDARY="${four_gib_disks[1]}"
    OSD_DISK_TERTIARY="${four_gib_disks[2]}"
    OSD_DISK_QUATERNARY="${four_gib_disks[3]}"
    WAL_DISK="${two_gib_disks[0]}"
    DB_DISK="${two_gib_disks[1]}"

    OSD_DEV_PRIMARY=$(vm_exec readlink -f "$OSD_DISK_PRIMARY")
    OSD_DEV_SECONDARY=$(vm_exec readlink -f "$OSD_DISK_SECONDARY")
    OSD_DEV_TERTIARY=$(vm_exec readlink -f "$OSD_DISK_TERTIARY")
    OSD_DEV_QUATERNARY=$(vm_exec readlink -f "$OSD_DISK_QUATERNARY")
    WAL_DEVNODE=$(vm_exec readlink -f "$WAL_DISK")
    DB_DEVNODE=$(vm_exec readlink -f "$DB_DISK")

    local all_nodes
    all_nodes=$(printf "%s\n" "$OSD_DEV_PRIMARY" "$OSD_DEV_SECONDARY" "$OSD_DEV_TERTIARY" "$OSD_DEV_QUATERNARY" "$WAL_DEVNODE" "$DB_DEVNODE")
    local unique_nodes
    unique_nodes=$(sort -u <<<"$all_nodes" | wc -l)
    if [[ "$unique_nodes" != "6" ]]; then
        fail "Resolved test devices are not distinct"
    fi

    info "Selected test disks:"
    info "  OSD primary    : ${OSD_DISK_PRIMARY} (${OSD_DEV_PRIMARY})"
    info "  OSD secondary  : ${OSD_DISK_SECONDARY} (${OSD_DEV_SECONDARY})"
    info "  OSD tertiary   : ${OSD_DISK_TERTIARY} (${OSD_DEV_TERTIARY})"
    info "  OSD quaternary : ${OSD_DISK_QUATERNARY} (${OSD_DEV_QUATERNARY})"
    info "  WAL backing    : ${WAL_DISK} (${WAL_DEVNODE})"
    info "  DB backing     : ${DB_DISK} (${DB_DEVNODE})"
}

# Test: List available disks and assert we can parse expected structure.
function test_dsl_disk_list() {
    set -eux

    local disk_list_json
    disk_list_json=$(vm_exec microceph disk list --json)

    local configured_count
    configured_count=$(jq -r '.ConfiguredDisks | length' <<<"$disk_list_json")
    local available_count
    available_count=$(jq -r '.AvailableDisks | length' <<<"$disk_list_json")

    assert_eq "$configured_count" "0" "Expected 0 configured disks before DSL add tests"
    assert_ge "$available_count" 6 "Expected at least 6 available disks"

    pass "Disk inventory is sane (configured=${configured_count}, available=${available_count})"
}

# Test: Core DSL matching behavior via API dry-run.
function test_dsl_expression_matching() {
    set -eux

    local payload
    local resp
    local count
    local validation_error
    local paths

    payload='{"path":[],"osd_match":"eq(@type, '\''scsi'\'')","dry_run":true}'
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" "" "Expected no validation error for eq(@type,'scsi')"

    count=$(jq -r '.metadata.dry_run_devices | length' <<<"$resp")
    assert_ge "$count" 4 "Expected at least 4 scsi devices in dry-run"

    paths=$(jq -r '.metadata.dry_run_devices[].path' <<<"$resp")
    assert_contains "$paths" "$OSD_DISK_PRIMARY" "Expected primary OSD disk in DSL match"
    assert_contains "$paths" "$OSD_DISK_SECONDARY" "Expected secondary OSD disk in DSL match"

    payload='{"path":[],"osd_match":"gt(@size, 3GiB)","dry_run":true}'
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" "" "Expected no validation error for gt(@size,3GiB)"

    paths=$(jq -r '.metadata.dry_run_devices[].path' <<<"$resp")
    assert_contains "$paths" "$OSD_DISK_PRIMARY" "Expected primary OSD disk in size match"
    assert_contains "$paths" "$OSD_DISK_SECONDARY" "Expected secondary OSD disk in size match"

    payload='{"path":[],"osd_match":"and(eq(@type, '\''scsi'\''), gt(@size, 3GiB))","dry_run":true}'
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" "" "Expected no validation error for combined match"

    paths=$(jq -r '.metadata.dry_run_devices[].path' <<<"$resp")
    assert_contains "$paths" "$OSD_DISK_PRIMARY"
    assert_contains "$paths" "$OSD_DISK_SECONDARY"

    payload='{"path":[],"osd_match":"eq(@type, '\''nvme'\'')","dry_run":true}'
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" "" "Expected no validation error for no-match expression"

    count=$(jq -r '.metadata.dry_run_devices | length' <<<"$resp")
    assert_eq "$count" "0" "Expected no nvme matches in this VM"

    pass "Core DSL matching behavior validated"
}

function test_dsl_invalid_expression() {
    set -eux

    local payload
    local resp
    local validation_error

    payload='{"path":[],"osd_match":"invalid(","dry_run":true}'
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")

    assert_contains "$validation_error" "invalid DSL expression" "Expected invalid DSL expression error"
    pass "Invalid DSL expression is rejected"
}

function test_dsl_cli_flag_validation() {
    set -eux

    local out

    if run_vm_capture out "microceph disk add --osd-match \"eq(@type, 'scsi')\" /dev/sdb"; then
        fail "Expected positional args + --osd-match to fail"
    fi
    assert_contains "$out" "cannot be used with positional"

    if run_vm_capture out "microceph disk add --osd-match \"eq(@type, 'scsi')\" --wal-match \"eq(@type, 'scsi')\" --dry-run"; then
        fail "Expected --wal-match without --wal-size to fail"
    fi
    assert_contains "$out" "--wal-size is required"

    if run_vm_capture out "microceph disk add --osd-match \"eq(@type, 'scsi')\" --db-match \"eq(@type, 'scsi')\" --dry-run"; then
        fail "Expected --db-match without --db-size to fail"
    fi
    assert_contains "$out" "--db-size is required"

    pass "CLI flag validation checks passed"
}

function test_dsl_match_mode_role_specific_flags_rejected() {
    set -eux

    local out
    local payload
    local resp
    local validation_error

    if run_vm_capture out "microceph disk add --osd-match \"eq(@type, 'scsi')\" --wal-wipe --dry-run"; then
        fail "Expected --wal-wipe in match mode to fail"
    fi
    assert_contains "$out" "--wal-wipe/--wal-encrypt/--db-wipe/--db-encrypt cannot be used"

    if run_vm_capture out "microceph disk add --osd-match \"eq(@type, 'scsi')\" --db-encrypt --dry-run"; then
        fail "Expected --db-encrypt in match mode to fail"
    fi
    assert_contains "$out" "--wal-wipe/--wal-encrypt/--db-wipe/--db-encrypt cannot be used"

    payload='{"path":[],"osd_match":"eq(@type, '\''scsi'\'')","dry_run":true,"walwipe":true}'
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_contains "$validation_error" "--wal-wipe/--wal-encrypt/--db-wipe/--db-encrypt"

    pass "Role-specific WAL/DB flags are rejected in match mode (CLI + API)"
}

# Validation boundaries: malformed/invalid/tiny/fractional WAL/DB sizes in CLI and API.
function test_dsl_size_validation_boundaries() {
    set -eux

    local payload
    local resp
    local validation_error
    local wal_part_count
    local wal_part_size
    local out

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"4XYZ","dry_run":true}
EOF
)
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_contains "$validation_error" "invalid wal size" "Expected invalid WAL unit to be rejected"

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","db_match":"eq(@devnode, '${DB_DEVNODE}')","db_size":"not-a-size","dry_run":true}
EOF
)
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_contains "$validation_error" "invalid db size" "Expected malformed DB size to be rejected"

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"0GiB","dry_run":true}
EOF
)
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_contains "$validation_error" "must be greater than zero" "Expected zero WAL size to be rejected"

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"0.5GiB","dry_run":true}
EOF
)
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" "" "Expected fractional WAL size to be accepted"
    wal_part_count=$(jq -r '[.metadata.dry_run_partitions[] | select(.role == "wal")] | length' <<<"$resp")
    assert_eq "$wal_part_count" "1"
    wal_part_size=$(jq -r '.metadata.dry_run_partitions[] | select(.role == "wal") | .part_size' <<<"$resp")
    assert_regex "$wal_part_size" '^512\.00 ?MiB$' "Expected 0.5GiB to plan as 512.00 MiB"

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"1MiB","dry_run":true}
EOF
)
    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" "" "Expected tiny WAL size to be accepted"
    wal_part_count=$(jq -r '[.metadata.dry_run_partitions[] | select(.role == "wal")] | length' <<<"$resp")
    assert_eq "$wal_part_count" "1"
    wal_part_size=$(jq -r '.metadata.dry_run_partitions[] | select(.role == "wal") | .part_size' <<<"$resp")
    assert_regex "$wal_part_size" '^1\.00 ?MiB$' "Expected 1MiB partition plan string"

    if run_vm_capture out "microceph disk add --osd-match \"eq(@devnode, '${OSD_DEV_PRIMARY}')\" --wal-match \"eq(@devnode, '${WAL_DEVNODE}')\" --wal-size 4XYZ --dry-run"; then
        fail "Expected CLI invalid WAL unit to fail"
    fi
    assert_contains "$out" "invalid wal size"

    if run_vm_capture out "microceph disk add --osd-match \"eq(@devnode, '${OSD_DEV_PRIMARY}')\" --db-match \"eq(@devnode, '${DB_DEVNODE}')\" --db-size not-a-size --dry-run"; then
        fail "Expected CLI malformed DB size to fail"
    fi
    assert_contains "$out" "invalid db size"

    if ! run_vm_capture out "microceph disk add --osd-match \"eq(@devnode, '${OSD_DEV_PRIMARY}')\" --wal-match \"eq(@devnode, '${WAL_DEVNODE}')\" --wal-size 0.5GiB --dry-run"; then
        echo "$out"
        fail "Expected CLI fractional WAL size dry-run to succeed"
    fi
    assert_contains "$out" "Planned partition creation"
    assert_regex "$out" '512\.00[[:space:]]*MiB' "Expected CLI output to include fractional WAL partition size"

    if ! run_vm_capture out "microceph disk add --osd-match \"eq(@devnode, '${OSD_DEV_PRIMARY}')\" --wal-match \"eq(@devnode, '${WAL_DEVNODE}')\" --wal-size 1MiB --dry-run"; then
        echo "$out"
        fail "Expected CLI tiny WAL size dry-run to succeed"
    fi
    assert_contains "$out" "Planned partition creation"
    assert_regex "$out" '1\.00[[:space:]]*MiB' "Expected CLI output to include tiny WAL partition size"

    pass "Size validation boundaries are covered for CLI and API"
}

# Safety: overlap between OSD and WAL/DB backing devices must be rejected.
function test_dsl_wal_db_overlap_rejected() {
    set -eux

    local payload
    local resp
    local validation_error
    local partition_count_resp

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","wal_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","wal_size":"1GiB","dry_run":true}
EOF
)

    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_contains "$validation_error" "device overlap detected"

    partition_count_resp=$(jq -r '.metadata.dry_run_partitions | length' <<<"$resp")
    assert_eq "$partition_count_resp" "0" "Expected no dry-run partitions on overlap error"

    pass "Overlap protection works"
}

# Safety: empty WAL/DB match sets should not be fatal in dry-run.
function test_dsl_wal_db_empty_match_nonfatal() {
    set -eux

    local payload
    local resp
    local validation_error
    local osd_count
    local wal_count
    local assigned_wal

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","wal_match":"eq(@type, 'nvme')","wal_size":"1GiB","dry_run":true}
EOF
)

    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" "" "Empty WAL matches should not be fatal"

    osd_count=$(jq -r '.metadata.dry_run_devices | length' <<<"$resp")
    wal_count=$(jq -r '.metadata.dry_run_wal_devices | length' <<<"$resp")
    assigned_wal=$(jq -r '.metadata.dry_run_assignments[0].wal_device // ""' <<<"$resp")

    assert_eq "$osd_count" "1" "Expected one matched OSD in empty-WAL scenario"
    assert_eq "$wal_count" "0" "Expected zero WAL devices in empty-WAL scenario"
    assert_eq "$assigned_wal" "" "Expected empty WAL assignment when no WAL matches"

    pass "Empty WAL match is non-fatal in dry-run"
}

# Safety: insufficient WAL/DB capacity must fail cleanly without side effects.
function test_dsl_wal_db_insufficient_capacity_non_destructive() {
    set -eux

    local configured_before
    local configured_after
    local wal_parts_before
    local wal_parts_after
    local db_parts_before
    local db_parts_after
    local payload
    local resp
    local validation_error

    configured_before=$(get_configured_count)
    wal_parts_before=$(partition_count "$WAL_DEVNODE")
    db_parts_before=$(partition_count "$DB_DEVNODE")

    payload=$(cat <<EOF
{"path":[],"osd_match":"or(eq(@devnode, '${OSD_DEV_PRIMARY}'), eq(@devnode, '${OSD_DEV_SECONDARY}'))","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"2GiB","db_match":"eq(@devnode, '${DB_DEVNODE}')","db_size":"2GiB","wipe":true,"dry_run":false}
EOF
)

    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_contains "$validation_error" "insufficient wal capacity" "Expected wal capacity validation error"

    configured_after=$(get_configured_count)
    wal_parts_after=$(partition_count "$WAL_DEVNODE")
    db_parts_after=$(partition_count "$DB_DEVNODE")

    assert_eq "$configured_after" "$configured_before" "Configured disk count changed despite validation failure"
    assert_eq "$wal_parts_after" "$wal_parts_before" "WAL partition table changed despite validation failure"
    assert_eq "$db_parts_after" "$db_parts_before" "DB partition table changed despite validation failure"

    pass "Insufficient capacity failure is non-destructive"
}

# Safety: dry-run plan must be internally consistent (partitions + assignments).
function test_dsl_wal_db_dry_run_plan_consistency() {
    set -eux

    local payload
    local resp
    local validation_error
    local osd_count
    local wal_count
    local db_count
    local part_count
    local wal_part_count
    local db_part_count
    local assignment_count
    local wal_part_path
    local db_part_path
    local assigned_wal
    local assigned_db
    local wal_part_size
    local db_part_size

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"1GiB","db_match":"eq(@devnode, '${DB_DEVNODE}')","db_size":"1GiB","wipe":true,"dry_run":true}
EOF
)

    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" "" "Expected no validation errors for valid WAL/DB dry-run"

    osd_count=$(jq -r '.metadata.dry_run_devices | length' <<<"$resp")
    wal_count=$(jq -r '.metadata.dry_run_wal_devices | length' <<<"$resp")
    db_count=$(jq -r '.metadata.dry_run_db_devices | length' <<<"$resp")
    part_count=$(jq -r '.metadata.dry_run_partitions | length' <<<"$resp")
    wal_part_count=$(jq -r '[.metadata.dry_run_partitions[] | select(.role == "wal")] | length' <<<"$resp")
    db_part_count=$(jq -r '[.metadata.dry_run_partitions[] | select(.role == "db")] | length' <<<"$resp")
    assignment_count=$(jq -r '.metadata.dry_run_assignments | length' <<<"$resp")

    assert_eq "$osd_count" "1"
    assert_eq "$wal_count" "1"
    assert_eq "$db_count" "1"
    assert_eq "$part_count" "2"
    assert_eq "$wal_part_count" "1"
    assert_eq "$db_part_count" "1"
    assert_eq "$assignment_count" "1"

    wal_part_path=$(jq -r '.metadata.dry_run_partitions[] | select(.role == "wal") | .part_path' <<<"$resp")
    db_part_path=$(jq -r '.metadata.dry_run_partitions[] | select(.role == "db") | .part_path' <<<"$resp")
    assigned_wal=$(jq -r '.metadata.dry_run_assignments[0].wal_device // ""' <<<"$resp")
    assigned_db=$(jq -r '.metadata.dry_run_assignments[0].db_device // ""' <<<"$resp")

    assert_eq "$assigned_wal" "$wal_part_path" "WAL assignment does not match planned WAL partition path"
    assert_eq "$assigned_db" "$db_part_path" "DB assignment does not match planned DB partition path"

    wal_part_size=$(jq -r '.metadata.dry_run_partitions[] | select(.role == "wal") | .part_size' <<<"$resp")
    db_part_size=$(jq -r '.metadata.dry_run_partitions[] | select(.role == "db") | .part_size' <<<"$resp")
    assert_regex "$wal_part_size" '^1\.00 ?GiB$' "Unexpected WAL dry-run partition size string"
    assert_regex "$db_part_size" '^1\.00 ?GiB$' "Unexpected DB dry-run partition size string"

    # Each planned partition should map to OSD index 0 in this one-OSD scenario.
    local non_zero_idx_count
    non_zero_idx_count=$(jq -r '[.metadata.dry_run_partitions[] | select(.for_osd_idx != 0)] | length' <<<"$resp")
    assert_eq "$non_zero_idx_count" "0"

    pass "Dry-run WAL/DB plan consistency validated"
}

# Determinism: repeated dry-run calls with identical payload should return identical planning output.
function test_dsl_dry_run_deterministic_output() {
    set -eux

    local payload
    local resp1
    local resp2
    local validation_error_1
    local validation_error_2
    local snapshot_1
    local snapshot_2

    payload=$(cat <<EOF
{"path":[],"osd_match":"or(eq(@devnode, '${OSD_DEV_PRIMARY}'), eq(@devnode, '${OSD_DEV_SECONDARY}'))","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"${SMALL_WALDB_PART_SIZE}","db_match":"eq(@devnode, '${DB_DEVNODE}')","db_size":"${SMALL_WALDB_PART_SIZE}","wipe":true,"dry_run":true}
EOF
)

    resp1=$(vm_post_disks "$payload")
    resp2=$(vm_post_disks "$payload")

    validation_error_1=$(jq -r '.metadata.validation_error // ""' <<<"$resp1")
    validation_error_2=$(jq -r '.metadata.validation_error // ""' <<<"$resp2")
    assert_eq "$validation_error_1" "" "Expected first dry-run call to succeed"
    assert_eq "$validation_error_2" "" "Expected second dry-run call to succeed"

    # Compare only planning-relevant fields and canonicalize JSON ordering (-S)
    # so cosmetic ordering differences don't produce false negatives.
    snapshot_1=$(jq -Sc '{dry_run_devices: .metadata.dry_run_devices, dry_run_wal_devices: .metadata.dry_run_wal_devices, dry_run_db_devices: .metadata.dry_run_db_devices, dry_run_partitions: .metadata.dry_run_partitions, dry_run_assignments: .metadata.dry_run_assignments}' <<<"$resp1")
    snapshot_2=$(jq -Sc '{dry_run_devices: .metadata.dry_run_devices, dry_run_wal_devices: .metadata.dry_run_wal_devices, dry_run_db_devices: .metadata.dry_run_db_devices, dry_run_partitions: .metadata.dry_run_partitions, dry_run_assignments: .metadata.dry_run_assignments}' <<<"$resp2")

    assert_eq "$snapshot_1" "$snapshot_2" "Dry-run planning output changed between identical requests"

    pass "Dry-run planning output is deterministic for identical requests"
}

# Safety + behavior: execute WAL/DB add and verify resulting partition + assignment state.
function test_dsl_wal_db_apply_and_verify_partitions() {
    set -eux

    local configured_before
    local configured_after
    local wal_parts_before
    local wal_parts_after
    local db_parts_before
    local db_parts_after
    local out

    configured_before=$(get_configured_count)
    wal_parts_before=$(partition_count "$WAL_DEVNODE")
    db_parts_before=$(partition_count "$DB_DEVNODE")

    if ! run_vm_capture out "microceph disk add --osd-match \"eq(@devnode, '${OSD_DEV_PRIMARY}')\" --wal-match \"eq(@devnode, '${WAL_DEVNODE}')\" --wal-size 1GiB --db-match \"eq(@devnode, '${DB_DEVNODE}')\" --db-size 1GiB --wipe"; then
        echo "$out"
        fail "WAL/DB disk add command failed"
    fi

    assert_not_contains "$out" "Failure" "WAL/DB add reported failure"
    assert_not_contains "$out" "Validation Error" "WAL/DB add unexpectedly returned validation error"

    wait_for_configured_count $((configured_before + 1)) 180
    configured_after=$(get_configured_count)
    assert_eq "$configured_after" "$((configured_before + 1))" "Expected exactly one new configured disk"

    wal_parts_after=$(partition_count "$WAL_DEVNODE")
    db_parts_after=$(partition_count "$DB_DEVNODE")
    assert_eq "$wal_parts_after" "$((wal_parts_before + 1))" "Expected exactly one new WAL partition"
    assert_eq "$db_parts_after" "$((db_parts_before + 1))" "Expected exactly one new DB partition"

    local wal_part
    local db_part
    wal_part=$(first_partition_path "$WAL_DEVNODE")
    db_part=$(first_partition_path "$DB_DEVNODE")

    if [[ -z "$wal_part" || -z "$db_part" ]]; then
        fail "Expected WAL/DB partition paths after add"
    fi

    local wal_size_bytes
    local db_size_bytes
    wal_size_bytes=$(block_size_bytes "$wal_part")
    db_size_bytes=$(block_size_bytes "$db_part")

    assert_size_close "$wal_size_bytes" "$ONE_GIB_BYTES" "$SIZE_TOLERANCE_BYTES" "WAL partition size"
    assert_size_close "$db_size_bytes" "$ONE_GIB_BYTES" "$SIZE_TOLERANCE_BYTES" "DB partition size"

    local osd_dir
    osd_dir=$(get_osd_dir_for_disk_path "$OSD_DISK_PRIMARY")

    vm_sh "test -L '${osd_dir}/block.wal'"
    vm_sh "test -L '${osd_dir}/block.db'"

    local wal_link_target
    local db_link_target
    local wal_part_real
    local db_part_real

    wal_link_target=$(vm_exec readlink -f "${osd_dir}/block.wal")
    db_link_target=$(vm_exec readlink -f "${osd_dir}/block.db")
    wal_part_real=$(vm_exec readlink -f "$wal_part")
    db_part_real=$(vm_exec readlink -f "$db_part")

    assert_eq "$wal_link_target" "$wal_part_real" "OSD WAL symlink target mismatch"
    assert_eq "$db_link_target" "$db_part_real" "OSD DB symlink target mismatch"

    pass "WAL/DB add path and on-disk partition state validated"
}

# After add, same disk should not be matched again as available OSD candidate.
function test_dsl_idempotency() {
    set -eux

    local payload
    local resp
    local validation_error
    local count
    local out

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_PRIMARY}')","dry_run":true}
EOF
)

    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" ""

    count=$(jq -r '.metadata.dry_run_devices | length' <<<"$resp")
    assert_eq "$count" "0" "Expected no dry-run match for already-configured OSD disk"

    if ! run_vm_capture out "microceph disk add --osd-match \"eq(@devnode, '${OSD_DEV_PRIMARY}')\" --dry-run"; then
        fail "Expected dry-run command to succeed in idempotency check"
    fi
    assert_contains "$out" "No devices matched the expression"

    pass "Idempotency behavior validated"
}

# Test pristine check behavior on remaining OSD candidate.
function test_dsl_pristine_check() {
    set -eux

    local configured_before
    local configured_after
    local out

    configured_before=$(get_configured_count)

    info "Marking ${OSD_DISK_SECONDARY} (${OSD_DEV_SECONDARY}) as non-pristine"
    vm_sh "dd if=/dev/urandom of='${OSD_DISK_SECONDARY}' bs=1M count=10 conv=fsync status=none"

    if run_vm_capture out "microceph disk add --osd-match \"eq(@devnode, '${OSD_DEV_SECONDARY}')\""; then
        fail "Expected pristine check failure without --wipe"
    fi

    assert_regex "$out" "not pristine|pristine check" "Expected pristine-check rejection"

    configured_after=$(get_configured_count)
    assert_eq "$configured_after" "$configured_before" "Configured disk count changed after pristine rejection"

    pass "Pristine check rejects dirty disk without --wipe"
}

# Verify --wipe makes dirty disk eligible in dry-run mode.
function test_dsl_pristine_with_wipe_dry_run() {
    set -eux

    local payload
    local resp
    local validation_error
    local count

    payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_SECONDARY}')","wipe":true,"dry_run":true}
EOF
)

    resp=$(vm_post_disks "$payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$resp")
    assert_eq "$validation_error" "" "Expected --wipe dry-run to bypass pristine error"

    count=$(jq -r '.metadata.dry_run_devices | length' <<<"$resp")
    assert_eq "$count" "1" "Expected dirty disk to be eligible with --wipe dry-run"

    pass "--wipe dry-run allows dirty disk"
}

# Regression: in match mode, --wipe applies to data OSDs only and must not wipe existing WAL/DB backing partitions.
function test_dsl_match_mode_wipe_preserves_existing_backing_partitions() {
    set -eux

    local configured_before
    local configured_after
    local wal_parts_before
    local wal_parts_after
    local db_parts_before
    local db_parts_after
    local wal_sentinel_num
    local db_sentinel_num
    local wal_sentinel_path
    local db_sentinel_path
    local dry_payload
    local dry_resp
    local dry_validation_error
    local planned_wal
    local planned_db
    local out

    configured_before=$(get_configured_count)
    wal_parts_before=$(partition_count "$WAL_DEVNODE")
    db_parts_before=$(partition_count "$DB_DEVNODE")

    # Plant tiny sentinel partitions first. If match-mode --wipe accidentally
    # wipes WAL/DB backing disks, these sentinel partitions will disappear.
    wal_sentinel_num=$((wal_parts_before + 1))
    db_sentinel_num=$((db_parts_before + 1))

    vm_sh "sgdisk --new=${wal_sentinel_num}:0:+${SENTINEL_PART_SIZE_SGDISK} --typecode=${wal_sentinel_num}:8300 '${WAL_DEVNODE}'"
    vm_sh "sgdisk --new=${db_sentinel_num}:0:+${SENTINEL_PART_SIZE_SGDISK} --typecode=${db_sentinel_num}:8300 '${DB_DEVNODE}'"
    vm_sh "udevadm settle || true"

    wal_sentinel_path=$(partition_path_by_number "$WAL_DEVNODE" "$wal_sentinel_num")
    db_sentinel_path=$(partition_path_by_number "$DB_DEVNODE" "$db_sentinel_num")

    if [[ -z "$wal_sentinel_path" || -z "$db_sentinel_path" ]]; then
        fail "Failed to resolve sentinel WAL/DB partition paths"
    fi

    vm_sh "test -b '${wal_sentinel_path}'"
    vm_sh "test -b '${db_sentinel_path}'"

    dry_payload=$(cat <<EOF
{"path":[],"osd_match":"eq(@devnode, '${OSD_DEV_TERTIARY}')","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"${SMALL_WALDB_PART_SIZE}","db_match":"eq(@devnode, '${DB_DEVNODE}')","db_size":"${SMALL_WALDB_PART_SIZE}","wipe":true,"dry_run":true}
EOF
)

    dry_resp=$(vm_post_disks "$dry_payload")
    dry_validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$dry_resp")
    assert_eq "$dry_validation_error" "" "Unexpected dry-run validation error in wipe-preservation test"

    planned_wal=$(jq -r --arg d "$OSD_DISK_TERTIARY" '.metadata.dry_run_assignments[] | select(.osd_device == $d) | .wal_device // ""' <<<"$dry_resp")
    planned_db=$(jq -r --arg d "$OSD_DISK_TERTIARY" '.metadata.dry_run_assignments[] | select(.osd_device == $d) | .db_device // ""' <<<"$dry_resp")
    if [[ -z "$planned_wal" || -z "$planned_db" ]]; then
        echo "$dry_resp" | jq . >&2 || true
        fail "Expected WAL/DB assignments for wipe-preservation test dry-run"
    fi

    if ! run_vm_capture out "microceph disk add --osd-match \"eq(@devnode, '${OSD_DEV_TERTIARY}')\" --wal-match \"eq(@devnode, '${WAL_DEVNODE}')\" --wal-size ${SMALL_WALDB_PART_SIZE} --db-match \"eq(@devnode, '${DB_DEVNODE}')\" --db-size ${SMALL_WALDB_PART_SIZE} --wipe"; then
        echo "$out"
        fail "Expected match-mode add with --wipe to succeed for data device"
    fi

    assert_not_contains "$out" "Failure"
    assert_not_contains "$out" "Validation Error"

    wait_for_configured_count $((configured_before + 1)) 180
    configured_after=$(get_configured_count)
    assert_eq "$configured_after" "$((configured_before + 1))" "Expected exactly one new configured disk in wipe-preservation test"

    vm_sh "partprobe '${WAL_DEVNODE}' >/dev/null 2>&1 || partx -u '${WAL_DEVNODE}' >/dev/null 2>&1 || true"
    vm_sh "partprobe '${DB_DEVNODE}' >/dev/null 2>&1 || partx -u '${DB_DEVNODE}' >/dev/null 2>&1 || true"
    vm_sh "udevadm settle || true"

    wal_parts_after=$(partition_count "$WAL_DEVNODE")
    db_parts_after=$(partition_count "$DB_DEVNODE")

    # +2 = one sentinel we created + one newly allocated partition for this OSD.
    # Any lower value strongly suggests destructive behavior on backing disks.
    assert_eq "$wal_parts_after" "$((wal_parts_before + 2))" "WAL backing partitions were unexpectedly reset/wiped"
    assert_eq "$db_parts_after" "$((db_parts_before + 2))" "DB backing partitions were unexpectedly reset/wiped"

    vm_sh "test -b '${wal_sentinel_path}'"
    vm_sh "test -b '${db_sentinel_path}'"

    pass "Match-mode --wipe preserves existing WAL/DB backing partitions"
}

# Multi-OSD black-box test: ensure dry-run assignments are unique and actual symlinks match planned assignments.
function test_dsl_wal_db_multi_osd_assignment_correctness() {
    set -eux

    local dry_payload
    local dry_resp
    local apply_payload
    local apply_resp
    local validation_error
    local osd_count
    local assignment_count
    local wal_part_count
    local db_part_count
    local unique_wal_assignments
    local unique_db_assignments
    local planned_wal_secondary
    local planned_db_secondary
    local planned_wal_quaternary
    local planned_db_quaternary
    local configured_before
    local configured_after
    local failure_count
    local osd_dir_secondary
    local osd_dir_quaternary
    local wal_link_secondary
    local db_link_secondary
    local wal_link_quaternary
    local db_link_quaternary
    local planned_wal_secondary_real
    local planned_db_secondary_real
    local planned_wal_quaternary_real
    local planned_db_quaternary_real

    dry_payload=$(cat <<EOF
{"path":[],"osd_match":"or(eq(@devnode, '${OSD_DEV_SECONDARY}'), eq(@devnode, '${OSD_DEV_QUATERNARY}'))","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"${SMALL_WALDB_PART_SIZE}","db_match":"eq(@devnode, '${DB_DEVNODE}')","db_size":"${SMALL_WALDB_PART_SIZE}","wipe":true,"dry_run":true}
EOF
)

    dry_resp=$(vm_post_disks "$dry_payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$dry_resp")
    assert_eq "$validation_error" "" "Expected valid multi-OSD WAL/DB dry-run"

    osd_count=$(jq -r '.metadata.dry_run_devices | length' <<<"$dry_resp")
    assignment_count=$(jq -r '.metadata.dry_run_assignments | length' <<<"$dry_resp")
    wal_part_count=$(jq -r '[.metadata.dry_run_partitions[] | select(.role == "wal")] | length' <<<"$dry_resp")
    db_part_count=$(jq -r '[.metadata.dry_run_partitions[] | select(.role == "db")] | length' <<<"$dry_resp")

    assert_eq "$osd_count" "2" "Expected two OSD data devices in multi-OSD dry-run"
    assert_eq "$assignment_count" "2" "Expected one assignment per OSD data device"
    assert_eq "$wal_part_count" "2" "Expected two planned WAL partitions"
    assert_eq "$db_part_count" "2" "Expected two planned DB partitions"

    unique_wal_assignments=$(jq -r '[.metadata.dry_run_assignments[].wal_device] | unique | length' <<<"$dry_resp")
    unique_db_assignments=$(jq -r '[.metadata.dry_run_assignments[].db_device] | unique | length' <<<"$dry_resp")
    assert_eq "$unique_wal_assignments" "2" "Expected unique WAL partition assignments per OSD"
    assert_eq "$unique_db_assignments" "2" "Expected unique DB partition assignments per OSD"

    planned_wal_secondary=$(jq -r --arg d "$OSD_DISK_SECONDARY" '.metadata.dry_run_assignments[] | select(.osd_device == $d) | .wal_device' <<<"$dry_resp")
    planned_db_secondary=$(jq -r --arg d "$OSD_DISK_SECONDARY" '.metadata.dry_run_assignments[] | select(.osd_device == $d) | .db_device' <<<"$dry_resp")
    planned_wal_quaternary=$(jq -r --arg d "$OSD_DISK_QUATERNARY" '.metadata.dry_run_assignments[] | select(.osd_device == $d) | .wal_device' <<<"$dry_resp")
    planned_db_quaternary=$(jq -r --arg d "$OSD_DISK_QUATERNARY" '.metadata.dry_run_assignments[] | select(.osd_device == $d) | .db_device' <<<"$dry_resp")

    if [[ -z "$planned_wal_secondary" || -z "$planned_db_secondary" || -z "$planned_wal_quaternary" || -z "$planned_db_quaternary" ]]; then
        fail "Failed to resolve dry-run WAL/DB assignments for both OSD devices"
    fi

    configured_before=$(get_configured_count)

    apply_payload=$(cat <<EOF
{"path":[],"osd_match":"or(eq(@devnode, '${OSD_DEV_SECONDARY}'), eq(@devnode, '${OSD_DEV_QUATERNARY}'))","wal_match":"eq(@devnode, '${WAL_DEVNODE}')","wal_size":"${SMALL_WALDB_PART_SIZE}","db_match":"eq(@devnode, '${DB_DEVNODE}')","db_size":"${SMALL_WALDB_PART_SIZE}","wipe":true,"dry_run":false}
EOF
)

    apply_resp=$(vm_post_disks "$apply_payload")
    validation_error=$(jq -r '.metadata.validation_error // ""' <<<"$apply_resp")
    assert_eq "$validation_error" "" "Unexpected validation error during multi-OSD add"

    failure_count=$(jq -r '[.metadata.report[]? | select(.report == "Failure")] | length' <<<"$apply_resp")
    assert_eq "$failure_count" "0" "Expected zero failed reports in multi-OSD add"

    wait_for_configured_count $((configured_before + 2)) 240
    configured_after=$(get_configured_count)
    assert_eq "$configured_after" "$((configured_before + 2))" "Expected exactly two new configured disks in multi-OSD add"

    osd_dir_secondary=$(get_osd_dir_for_disk_path "$OSD_DISK_SECONDARY")
    osd_dir_quaternary=$(get_osd_dir_for_disk_path "$OSD_DISK_QUATERNARY")

    vm_sh "test -L '${osd_dir_secondary}/block.wal'"
    vm_sh "test -L '${osd_dir_secondary}/block.db'"
    vm_sh "test -L '${osd_dir_quaternary}/block.wal'"
    vm_sh "test -L '${osd_dir_quaternary}/block.db'"

    wal_link_secondary=$(vm_exec readlink -f "${osd_dir_secondary}/block.wal")
    db_link_secondary=$(vm_exec readlink -f "${osd_dir_secondary}/block.db")
    wal_link_quaternary=$(vm_exec readlink -f "${osd_dir_quaternary}/block.wal")
    db_link_quaternary=$(vm_exec readlink -f "${osd_dir_quaternary}/block.db")

    # Dry-run plans use stable /dev/disk/by-id paths, while OSD symlinks may
    # resolve through kernel names (/dev/sdXn). Normalize both sides to real
    # device nodes before comparing.
    planned_wal_secondary_real=$(vm_exec readlink -f "$planned_wal_secondary")
    planned_db_secondary_real=$(vm_exec readlink -f "$planned_db_secondary")
    planned_wal_quaternary_real=$(vm_exec readlink -f "$planned_wal_quaternary")
    planned_db_quaternary_real=$(vm_exec readlink -f "$planned_db_quaternary")

    assert_eq "$wal_link_secondary" "$planned_wal_secondary_real" "Secondary OSD WAL link does not match dry-run assignment"
    assert_eq "$db_link_secondary" "$planned_db_secondary_real" "Secondary OSD DB link does not match dry-run assignment"
    assert_eq "$wal_link_quaternary" "$planned_wal_quaternary_real" "Quaternary OSD WAL link does not match dry-run assignment"
    assert_eq "$db_link_quaternary" "$planned_db_quaternary_real" "Quaternary OSD DB link does not match dry-run assignment"

    assert_ne "$wal_link_secondary" "$wal_link_quaternary" "Expected distinct WAL partitions per OSD"
    assert_ne "$db_link_secondary" "$db_link_quaternary" "Expected distinct DB partitions per OSD"

    pass "Multi-OSD WAL/DB assignment is consistent across dry-run and apply"
}

function show_dsl_final_status() {
    set -eux

    echo ""
    echo "=== Final Cluster Status ==="
    vm_exec microceph status || true
    vm_exec microceph disk list || true
    vm_exec lsblk || true
}

# Run all DSL tests
function run_dsl_tests() {
    set -eux

    echo ""
    echo "=== Running DSL tests (with WAL/DB safety focus) ==="

    select_test_disks

    test_dsl_disk_list
    test_dsl_expression_matching
    test_dsl_invalid_expression
    test_dsl_cli_flag_validation
    test_dsl_match_mode_role_specific_flags_rejected
    test_dsl_size_validation_boundaries

    test_dsl_wal_db_overlap_rejected
    test_dsl_wal_db_empty_match_nonfatal
    test_dsl_wal_db_insufficient_capacity_non_destructive
    test_dsl_wal_db_dry_run_plan_consistency
    test_dsl_dry_run_deterministic_output
    test_dsl_wal_db_apply_and_verify_partitions
    test_dsl_idempotency

    test_dsl_pristine_check
    test_dsl_pristine_with_wipe_dry_run

    test_dsl_match_mode_wipe_preserves_existing_backing_partitions
    test_dsl_wal_db_multi_osd_assignment_correctness

    show_dsl_final_status

    echo ""
    pass "All DSL functional tests completed"
}

# Main test execution (standalone mode)
function run_dsl_functest() {
    if [ "$NO_CLEANUP" -eq 0 ]; then
        trap cleanup_dsl_test EXIT
    fi

    setup_dsl_test
    install_microceph_in_vm
    run_dsl_tests
}

# Parse command line arguments for standalone execution
function parse_dsl_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --vm-name)
                VM_NAME="$2"
                DISK1_NAME="${VM_NAME}-disk1"
                DISK2_NAME="${VM_NAME}-disk2"
                DISK3_NAME="${VM_NAME}-disk3"
                DISK4_NAME="${VM_NAME}-disk4"
                DISK5_NAME="${VM_NAME}-disk5"
                DISK6_NAME="${VM_NAME}-disk6"
                shift 2
                ;;
            --snap-path)
                SNAP_PATH="$2"
                shift 2
                ;;
            --snap-channel)
                SNAP_CHANNEL="$2"
                shift 2
                ;;
            --storage-pool)
                STORAGE_POOL="$2"
                shift 2
                ;;
            --no-cleanup)
                NO_CLEANUP=1
                shift
                ;;
            --setup-lxd)
                SETUP_LXD=1
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS] [FUNCTION]"
                echo ""
                echo "Options:"
                echo "  --vm-name NAME       Name for the test VM (default: microceph-dsl-test)"
                echo "  --snap-path PATH     Path (or glob) to local snap file to install"
                echo "  --snap-channel CHAN  Snap channel to install from (default: latest/edge)"
                echo "  --storage-pool POOL  LXD storage pool to use (default: default)"
                echo "  --no-cleanup         Don't cleanup VM and volumes on exit"
                echo "  --setup-lxd          Run actionutils.setup_lxd() before setup"
                echo "  --help               Show this help message"
                echo ""
                echo "Functions (can be called directly):"
                echo "  setup_dsl_test"
                echo "  install_microceph_in_vm"
                echo "  run_dsl_tests"
                echo "  test_dsl_*"
                exit 0
                ;;
            *)
                # If argument doesn't start with --, treat it as a function name.
                if [[ "$1" != --* ]]; then
                    local run="$1"
                    shift
                    "$run" "$@"
                    exit $?
                fi
                fail "Unknown option: $1"
                ;;
        esac
    done

    run_dsl_functest
}

# Entry point - if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_dsl_args "$@"
fi
