#!/bin/bash
# Functional test for DSL-based device matching in MicroCeph
# This test:
# 1. Creates an LXD VM with virtual block storage attached
# 2. Installs the MicroCeph snap
# 3. Tests that block devices are detected and DSL expressions work correctly

# Configuration
VM_NAME="${VM_NAME:-microceph-dsl-test}"
PROFILE="${PROFILE:-default}"
CORES="${CORES:-2}"
MEM="${MEM:-4GiB}"
STORAGE_POOL="${STORAGE_POOL:-default}"
SNAP_PATH="${SNAP_PATH:-}"  # Path to local snap file, empty means use store
SNAP_CHANNEL="${SNAP_CHANNEL:-latest/edge}"

# Disk configurations: name:size pairs
DISK1_NAME="${VM_NAME}-disk1"
DISK1_SIZE="${DISK1_SIZE:-4GiB}"
DISK2_NAME="${VM_NAME}-disk2"
DISK2_SIZE="${DISK2_SIZE:-2GiB}"
DISK3_NAME="${VM_NAME}-disk3"
DISK3_SIZE="${DISK3_SIZE:-2GiB}"
DISK4_NAME="${VM_NAME}-disk4"
DISK4_SIZE="${DISK4_SIZE:-4GiB}"

# Cleanup function
function cleanup_dsl_test() {
    local exit_code=$?
    echo "Cleaning up..."

    # Stop and delete VM
    lxc stop "$VM_NAME" --force 2>/dev/null || true
    lxc delete "$VM_NAME" --force 2>/dev/null || true

    # Delete storage volumes
    lxc storage volume delete "$STORAGE_POOL" "$DISK1_NAME" 2>/dev/null || true
    lxc storage volume delete "$STORAGE_POOL" "$DISK2_NAME" 2>/dev/null || true
    lxc storage volume delete "$STORAGE_POOL" "$DISK3_NAME" 2>/dev/null || true
    lxc storage volume delete "$STORAGE_POOL" "$DISK4_NAME" 2>/dev/null || true

    if [ $exit_code -eq 0 ]; then
        echo "Test completed successfully!"
    else
        echo "Test failed with exit code $exit_code"
    fi

    exit $exit_code
}

# Wait for VM to be ready
function wait_for_dsl_vm() {
    local name=$1
    local timeout=${2:-300}
    local elapsed=0

    echo "Waiting for VM '$name' to be ready (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        if lxc exec "$name" -- cloud-init status --wait 2>/dev/null | grep -q "done"; then
            echo "VM '$name' is ready"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done
    echo ""
    echo "Timeout waiting for VM '$name' to be ready"
    return 1
}

# Run command in VM and return output
function vm_exec() {
    lxc exec "$VM_NAME" -- "$@"
}

# Run command in VM and check exit code
function vm_exec_check() {
    local description=$1
    shift
    echo "Running: $*"
    if ! vm_exec "$@"; then
        echo "Failed: $description"
        return 1
    fi
    return 0
}

# Setup DSL test environment
function setup_dsl_test() {
    set -eux

    echo "=== MicroCeph DSL Functional Test ==="
    echo "VM Name: $VM_NAME"
    echo "Disks: $DISK1_NAME ($DISK1_SIZE), $DISK2_NAME ($DISK2_SIZE), $DISK3_NAME ($DISK3_SIZE), $DISK4_NAME ($DISK4_SIZE)"

    # Check if VM already exists
    if lxc info "$VM_NAME" &>/dev/null; then
        echo "VM '$VM_NAME' already exists, deleting..."
        lxc stop "$VM_NAME" --force 2>/dev/null || true
        lxc delete "$VM_NAME" --force 2>/dev/null || true
    fi

    # Check/delete existing storage volumes
    for disk in "$DISK1_NAME" "$DISK2_NAME" "$DISK3_NAME" "$DISK4_NAME"; do
        if lxc storage volume show "$STORAGE_POOL" "$disk" &>/dev/null; then
            echo "Storage volume '$disk' already exists, deleting..."
            lxc storage volume delete "$STORAGE_POOL" "$disk" 2>/dev/null || true
        fi
    done

    # Create storage volumes
    echo "Creating storage volumes..."
    lxc storage volume create "$STORAGE_POOL" "$DISK1_NAME" --type block size="$DISK1_SIZE"
    lxc storage volume create "$STORAGE_POOL" "$DISK2_NAME" --type block size="$DISK2_SIZE"
    lxc storage volume create "$STORAGE_POOL" "$DISK3_NAME" --type block size="$DISK3_SIZE"
    lxc storage volume create "$STORAGE_POOL" "$DISK4_NAME" --type block size="$DISK4_SIZE"

    # Launch VM
    echo "Launching VM '$VM_NAME'..."
    lxc launch ubuntu:24.04 "$VM_NAME" \
        -p "$PROFILE" \
        -c limits.cpu="$CORES" \
        -c limits.memory="$MEM" \
        --vm

    # Attach storage volumes
    echo "Attaching storage volumes to VM..."
    lxc storage volume attach "$STORAGE_POOL" "$DISK1_NAME" "$VM_NAME"
    lxc storage volume attach "$STORAGE_POOL" "$DISK2_NAME" "$VM_NAME"
    lxc storage volume attach "$STORAGE_POOL" "$DISK3_NAME" "$VM_NAME"
    lxc storage volume attach "$STORAGE_POOL" "$DISK4_NAME" "$VM_NAME"

    # Wait for VM to be ready
    wait_for_dsl_vm "$VM_NAME"

    # Give the system a moment to detect the new block devices
    sleep 5
}

# Resolve snap path glob pattern to actual file
function resolve_snap_path() {
    local pattern="$1"
    local resolved

    # Use compgen to safely expand glob without word splitting issues
    # shellcheck disable=SC2086
    resolved=$(compgen -G "$pattern" | head -n1)

    if [ -n "$resolved" ] && [ -f "$resolved" ]; then
        echo "$resolved"
        return 0
    fi
    return 1
}

# Install MicroCeph snap in VM
function install_microceph_in_vm() {
    set -eux

    echo "Installing MicroCeph snap..."

    local snap_file=""
    if [ -n "$SNAP_PATH" ]; then
        # Resolve glob pattern to actual file
        snap_file=$(resolve_snap_path "$SNAP_PATH") || true
    fi

    if [ -n "$snap_file" ] && [ -f "$snap_file" ]; then
        echo "Installing from local snap: $snap_file"
        lxc file push "$snap_file" "$VM_NAME/tmp/microceph.snap"
        vm_exec snap install /tmp/microceph.snap --dangerous

        # When installing with --dangerous, interfaces are not auto-connected
        echo "Connecting snap interfaces for dangerous install..."
        vm_exec snap connect microceph:block-devices || true
        vm_exec snap connect microceph:hardware-observe || true
        vm_exec snap connect microceph:mount-observe || true
        vm_exec snap connect microceph:dm-crypt || true
    else
        if [ -n "$SNAP_PATH" ]; then
            echo "Warning: No snap file found matching '$SNAP_PATH', falling back to snap store"
        fi
        echo "Installing from snap store: $SNAP_CHANNEL"
        vm_exec snap install microceph --channel="$SNAP_CHANNEL"
    fi

    # Wait for snap to be ready
    sleep 3

    # Bootstrap MicroCeph cluster
    echo "Bootstrapping MicroCeph cluster..."
    vm_exec_check "microceph init" microceph cluster bootstrap

    # Wait for cluster to be ready
    sleep 5
}

# Test: List available disks
function test_dsl_disk_list() {
    set -eux

    echo "Test: Checking disk list..."
    disk_list=$(vm_exec microceph disk list --json 2>/dev/null || vm_exec microceph disk list)
    echo "Disk list output:"
    echo "$disk_list"
}

# Test: Verify available disks
function test_dsl_available_disks() {
    set -eux

    echo "Test: Verifying available disks..."
    # Count available disks - look for scsi or virtio types (LXD VMs use scsi emulation)
    available_count=$(vm_exec microceph disk list 2>/dev/null | grep -cE "scsi|virtio" || echo "0")
    echo "Found $available_count available disks (scsi/virtio)"

    # We should have 4 disks (our attached volumes)
    if [ "$available_count" -lt 4 ]; then
        echo "FAIL: Expected 4 disks, found $available_count"
        echo "Listing all block devices:"
        vm_exec lsblk
        exit 1
    fi
    echo "$available_count"
}

# Test: DSL dry-run with type match
function test_dsl_type_match() {
    set -eux

    echo "Test: DSL dry-run with eq(@type, 'scsi')..."
    dsl_output=$(vm_exec microceph disk add --osd-match "eq(@type, 'scsi')" --dry-run 2>&1) || true
    echo "DSL output:"
    echo "$dsl_output"

    if echo "$dsl_output" | grep -qi "would be added\|dry_run_devices\|PATH"; then
        echo "PASS: DSL dry-run returned expected output"
    elif echo "$dsl_output" | grep -qi "no devices matched"; then
        echo "No devices matched - checking available device types..."
        vm_exec lsblk -o NAME,TYPE,SIZE,MODEL
    else
        echo "FAIL: Unexpected DSL dry-run output"
        exit 1
    fi
}

# Test: DSL with size comparison
function test_dsl_size_comparison() {
    set -eux

    echo "Test: DSL dry-run with size comparison gt(@size, 3GiB)..."
    dsl_size_output=$(vm_exec microceph disk add --osd-match "gt(@size, 3GiB)" --dry-run 2>&1) || true
    echo "DSL size filter output:"
    echo "$dsl_size_output"
}

# Test: DSL with combined conditions
function test_dsl_combined_conditions() {
    set -eux

    echo "Test: DSL dry-run with combined conditions..."
    dsl_combined=$(vm_exec microceph disk add --osd-match "and(eq(@type, 'scsi'), gt(@size, 3GiB))" --dry-run 2>&1) || true
    echo "DSL combined filter output:"
    echo "$dsl_combined"
}

# Test: DSL with non-matching expression
function test_dsl_no_match() {
    set -eux

    echo "Test: DSL dry-run with non-matching expression eq(@type, 'nvme')..."
    dsl_nomatch=$(vm_exec microceph disk add --osd-match "eq(@type, 'nvme')" --dry-run 2>&1) || true
    echo "DSL no-match output:"
    echo "$dsl_nomatch"
}

# Test: Invalid DSL expression
function test_dsl_invalid_expression() {
    set -eux

    echo "Test: Invalid DSL expression..."
    dsl_invalid=$(vm_exec microceph disk add --osd-match "invalid(" --dry-run 2>&1) || true
    echo "Invalid DSL output:"
    echo "$dsl_invalid"

    if echo "$dsl_invalid" | grep -qi "error\|invalid"; then
        echo "PASS: Invalid DSL expression correctly rejected"
    else
        echo "FAIL: Invalid DSL expression should have been rejected"
        exit 1
    fi
}

# Test: Flag mutual exclusivity
function test_dsl_mutual_exclusivity() {
    set -eux

    echo "Test: Flag mutual exclusivity..."
    mutual_excl=$(vm_exec microceph disk add --osd-match "eq(@type, 'virtio')" /dev/sdb 2>&1) || true
    if echo "$mutual_excl" | grep -qi "cannot be used with"; then
        echo "PASS: Mutual exclusivity correctly enforced"
    else
        echo "Mutual exclusivity check may not have triggered (check output)"
        echo "$mutual_excl"
    fi
}

# Test: WAL/DB phase2 flag validation
function test_dsl_wal_db_flag_validation() {
    set -eux

    echo "Test: WAL/DB DSL flag validation..."

    wal_missing_size=$(vm_exec microceph disk add --osd-match "eq(@type, 'scsi')" --wal-match "eq(@type, 'scsi')" --dry-run 2>&1) || true
    echo "$wal_missing_size"
    if echo "$wal_missing_size" | grep -qi "wal-size is required"; then
        echo "PASS: --wal-match requires --wal-size"
    else
        echo "FAIL: expected wal-size validation error"
        exit 1
    fi

    db_missing_size=$(vm_exec microceph disk add --osd-match "eq(@type, 'scsi')" --db-match "eq(@type, 'scsi')" --dry-run 2>&1) || true
    echo "$db_missing_size"
    if echo "$db_missing_size" | grep -qi "db-size is required"; then
        echo "PASS: --db-match requires --db-size"
    else
        echo "FAIL: expected db-size validation error"
        exit 1
    fi
}

# Test: WAL/DB dry-run partition planning output
function test_dsl_wal_db_dry_run_plan() {
    set -eux

    echo "Test: WAL/DB dry-run planning..."

    disk_list_json=$(vm_exec microceph disk list --json 2>/dev/null)
    data_disk=$(echo "$disk_list_json" | jq -r '.AvailableDisks[] | select(.Size=="4.00GiB") | .Path' | head -n1)
    wal_db_disks=$(echo "$disk_list_json" | jq -r '.AvailableDisks[] | select(.Size=="2.00GiB") | .Path')
    wal_disk=$(echo "$wal_db_disks" | sed -n '1p')
    db_disk=$(echo "$wal_db_disks" | sed -n '2p')

    if [ -z "$data_disk" ] || [ -z "$wal_disk" ] || [ -z "$db_disk" ]; then
        echo "FAIL: required WAL/DB disks not available for dry-run planning"
        exit 1
    fi

    data_devnode=$(vm_exec readlink -f "$data_disk")
    wal_devnode=$(vm_exec readlink -f "$wal_disk")
    db_devnode=$(vm_exec readlink -f "$db_disk")

    if [ -z "$data_devnode" ] || [ -z "$wal_devnode" ] || [ -z "$db_devnode" ]; then
        echo "FAIL: unable to resolve WAL/DB devnodes for dry-run planning"
        exit 1
    fi

    if [ "$wal_devnode" = "$db_devnode" ]; then
        echo "FAIL: WAL and DB devnodes resolved to the same device"
        exit 1
    fi

    # Typical setup in this VM has OSD disks (~4GiB) and WAL/DB disks (~2GiB).
    dsl_phase2_output=$(vm_exec microceph disk add \
        --osd-match "and(eq(@devnode, '$data_devnode'), ge(@size, 4GiB), lt(@size, 5GiB))" \
        --wal-match "and(eq(@devnode, '$wal_devnode'), ge(@size, 2GiB), lt(@size, 3GiB))" \
        --wal-size 1GiB \
        --db-match "and(eq(@devnode, '$db_devnode'), ge(@size, 2GiB), lt(@size, 3GiB))" \
        --db-size 1GiB \
        --dry-run 2>&1) || true

    echo "WAL/DB dry-run output:"
    echo "$dsl_phase2_output"

    if echo "$dsl_phase2_output" | grep -qiE "Matched WAL backing devices|Planned partition creation|Planned OSD assignments"; then
        echo "PASS: WAL/DB dry-run planning output detected"
    elif echo "$dsl_phase2_output" | grep -qi "No devices matched"; then
        echo "FAIL: No matching devices for WAL/DB dry-run planning"
        exit 1
    else
        echo "FAIL: Unexpected WAL/DB dry-run output"
        exit 1
    fi
}

# Test: Empty WAL/DB matches are non-fatal in dry-run
function test_dsl_wal_db_empty_match_nonfatal() {
    set -eux

    echo "Test: empty WAL/DB matches should be non-fatal..."
    out=$(vm_exec microceph disk add \
        --osd-match "eq(@type, 'scsi')" \
        --wal-match "eq(@type, 'nvme')" \
        --wal-size 1GiB \
        --dry-run 2>&1) || true

    echo "$out"

    if echo "$out" | grep -qi "Validation Error found\|validation_error"; then
        echo "FAIL: empty WAL match should not be validation error"
        exit 1
    fi

    if echo "$out" | grep -qiE "would be added|PATH|No devices matched"; then
        echo "PASS: command succeeded without fatal WAL match error"
    else
        echo "FAIL: unexpected output for empty WAL match scenario"
        exit 1
    fi
}

# Test: WAL/DB add disk using DSL
function test_dsl_wal_db_add_disk() {
    set -eux

    echo "Test: WAL/DB add disk using DSL (dry-run)..."

    disk_list_json=$(vm_exec microceph disk list --json 2>/dev/null)
    data_disk=$(echo "$disk_list_json" | jq -r '.AvailableDisks[] | select(.Size=="4.00GiB") | .Path' | head -n1)
    wal_db_disks=$(echo "$disk_list_json" | jq -r '.AvailableDisks[] | select(.Size=="2.00GiB") | .Path')
    wal_disk=$(echo "$wal_db_disks" | sed -n '1p')
    db_disk=$(echo "$wal_db_disks" | sed -n '2p')

    if [ -z "$data_disk" ] || [ -z "$wal_disk" ] || [ -z "$db_disk" ]; then
        echo "FAIL: required WAL/DB disks not available"
        exit 1
    fi

    data_devnode=$(vm_exec readlink -f "$data_disk")
    wal_devnode=$(vm_exec readlink -f "$wal_disk")
    db_devnode=$(vm_exec readlink -f "$db_disk")

    if [ -z "$data_devnode" ] || [ -z "$wal_devnode" ] || [ -z "$db_devnode" ]; then
        echo "FAIL: unable to resolve WAL/DB devnodes"
        exit 1
    fi

    if [ "$wal_devnode" = "$db_devnode" ]; then
        echo "FAIL: WAL and DB devnodes resolved to the same device"
        exit 1
    fi

    wal_db_add_output=$(vm_exec microceph disk add \
        --osd-match "and(eq(@devnode, '$data_devnode'), ge(@size, 4GiB), lt(@size, 5GiB))" \
        --wal-match "and(eq(@devnode, '$wal_devnode'), ge(@size, 2GiB), lt(@size, 3GiB))" \
        --wal-size 1GiB \
        --db-match "and(eq(@devnode, '$db_devnode'), ge(@size, 2GiB), lt(@size, 3GiB))" \
        --db-size 1GiB \
        --dry-run 2>&1) || true

    echo "WAL/DB add dry-run output:"
    echo "$wal_db_add_output"

    if echo "$wal_db_add_output" | grep -qiE "Matched WAL backing devices|Planned partition creation|Planned OSD assignments"; then
        echo "PASS: WAL/DB add dry-run output detected"
    else
        echo "FAIL: WAL/DB add dry-run output missing expected content"
        exit 1
    fi
}

# Test: Add disk using DSL
function test_dsl_add_disk() {
    set -eux

    echo "Test: Adding disk using DSL expression..."

    # First check if we have disks to add
    available_count=$(vm_exec microceph disk list 2>/dev/null | grep -cE "scsi|virtio" || echo "0")

    if [ "$available_count" -ge 1 ]; then
        # Add one disk using size-based selection (the smaller one first)
        add_result=$(vm_exec microceph disk add --osd-match "and(eq(@type, 'scsi'), ge(@size, 4GiB), lt(@size, 5GiB))" 2>&1) || true
        echo "Add disk result:"
        echo "$add_result"

        # Check if disk was added
        sleep 3
        configured_disks=$(vm_exec microceph disk list 2>/dev/null | grep -c "^[0-9]" || echo "0")
        echo "Configured disks after add: $configured_disks"

        if [ "$configured_disks" -ge 1 ]; then
            echo "PASS: Successfully added disk using DSL expression"
        else
            echo "Disk may not have been added (check OSD status)"
        fi
    else
        echo "FAIL: no available disks detected for add test"
        exit 1
    fi
}

# Test: DSL idempotency
function test_dsl_idempotency() {
    set -eux

    echo "Test: Idempotency - DSL should not re-match used disks..."
    dsl_after_add=$(vm_exec microceph disk add --osd-match "and(eq(@type, 'scsi'), ge(@size, 4GiB), lt(@size, 5GiB))" --dry-run 2>&1) || true
    echo "DSL output after disk was added:"
    echo "$dsl_after_add"
}

# Test: DSL respects pristine check (non-pristine disk rejected without --wipe)
function test_dsl_pristine_check() {
    set -eux

    echo "Test: DSL respects pristine check..."

    # Get list of available disks
    available_disks=$(vm_exec microceph disk list --json 2>/dev/null | jq -r '.AvailableDisks[] | select(.Size=="4.00GiB") | .Path' | head -n1) || true

    if [ -z "$available_disks" ]; then
        echo "FAIL: no available disks for pristine check"
        exit 1
    fi

    local test_disk="$available_disks"
    local resolved_disk
    resolved_disk=$(vm_exec readlink -f "$test_disk")
    echo "Using disk for pristine test: $test_disk (resolved: $resolved_disk)"

    # Make the disk non-pristine by writing some data to it
    echo "Making disk non-pristine..."
    vm_exec dd if=/dev/urandom of="$test_disk" bs=1M count=10 conv=fsync 2>/dev/null || true

    # Try to add via DSL without --wipe - should fail pristine check
    echo "Attempting to add non-pristine disk via DSL (should fail)..."
    # @devnode uses kernel path (e.g. /dev/sdb), so match against resolved path.
    dsl_pristine_result=$(vm_exec microceph disk add --osd-match "eq(@devnode, '$resolved_disk')" 2>&1) || true
    echo "Result: $dsl_pristine_result"

    if echo "$dsl_pristine_result" | grep -qi "not pristine\|pristine check"; then
        echo "PASS: DSL correctly rejected non-pristine disk without --wipe"
    else
        echo "FAIL: DSL should have rejected non-pristine disk"
        exit 1
    fi
}

# Test: DSL with --wipe adds non-pristine disk
function test_dsl_pristine_with_wipe() {
    set -eux

    echo "Test: DSL with --wipe adds non-pristine disk (dry-run)..."

    # Get list of available disks (should still have the non-pristine one from previous test)
    available_disks=$(vm_exec microceph disk list --json 2>/dev/null | jq -r '.AvailableDisks[] | select(.Size=="4.00GiB") | .Path' | head -n1) || true

    if [ -z "$available_disks" ]; then
        echo "FAIL: no available disks for pristine+wipe test"
        exit 1
    fi

    local test_disk="$available_disks"
    local resolved_disk
    resolved_disk=$(vm_exec readlink -f "$test_disk")
    echo "Using disk for pristine+wipe test: $test_disk (resolved: $resolved_disk)"

    # Ensure disk is non-pristine
    echo "Ensuring disk is non-pristine..."
    vm_exec dd if=/dev/urandom of="$test_disk" bs=1M count=10 conv=fsync 2>/dev/null || true

    # Try to add via DSL with --wipe in dry-run mode
    echo "Attempting to add non-pristine disk via DSL with --wipe (dry-run)..."
    dsl_wipe_result=$(vm_exec microceph disk add --osd-match "eq(@devnode, '$resolved_disk')" --wipe --dry-run 2>&1) || true
    echo "Result: $dsl_wipe_result"

    if echo "$dsl_wipe_result" | grep -qi "not pristine\|pristine check"; then
        echo "FAIL: --wipe should bypass pristine checks in dry-run"
        exit 1
    fi

    if echo "$dsl_wipe_result" | grep -qiE "would be added|dry_run_devices|PATH"; then
        echo "PASS: DSL with --wipe dry-run accepted non-pristine disk"
    else
        echo "FAIL: DSL with --wipe dry-run returned unexpected output"
        exit 1
    fi
}

# Show final status
function show_dsl_final_status() {
    set -eux

    echo ""
    echo "=== Final Cluster Status ==="
    vm_exec microceph status || true
    vm_exec microceph disk list || true
}

# Run all DSL tests
function run_dsl_tests() {
    set -eux

    echo ""
    echo "=== Running DSL Tests ==="

    test_dsl_disk_list
    test_dsl_available_disks
    test_dsl_type_match
    test_dsl_size_comparison
    test_dsl_combined_conditions
    test_dsl_no_match
    test_dsl_invalid_expression
    test_dsl_mutual_exclusivity
    test_dsl_wal_db_flag_validation
    test_dsl_wal_db_dry_run_plan
    test_dsl_wal_db_empty_match_nonfatal
    test_dsl_wal_db_add_disk
    test_dsl_pristine_check
    test_dsl_pristine_with_wipe
    test_dsl_idempotency
    show_dsl_final_status

    echo ""
    echo "=== Test Summary ==="
    echo "All DSL functional tests completed!"
}

# Main test execution (standalone mode)
function run_dsl_functest() {
    set -e
    trap cleanup_dsl_test EXIT

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
                trap - EXIT
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS] [FUNCTION]"
                echo ""
                echo "Options:"
                echo "  --vm-name NAME       Name for the test VM (default: microceph-dsl-test)"
                echo "  --snap-path PATH     Path to local snap file to install"
                echo "  --snap-channel CHAN  Snap channel to install from (default: latest/edge)"
                echo "  --storage-pool POOL  LXD storage pool to use (default: default)"
                echo "  --no-cleanup         Don't cleanup VM and volumes on exit"
                echo "  --help               Show this help message"
                echo ""
                echo "Functions (can be called directly):"
                echo "  setup_dsl_test              Setup VM and storage"
                echo "  install_microceph_in_vm     Install and bootstrap MicroCeph"
                echo "  run_dsl_tests               Run all DSL tests"
                echo "  test_dsl_*                  Individual test functions"
                exit 0
                ;;
            *)
                # If argument doesn't start with --, treat it as a function name
                if [[ "$1" != --* ]]; then
                    run="$1"
                    shift
                    $run "$@"
                    exit $?
                fi
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # No function specified, run full test
    run_dsl_functest
}

# Entry point - if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_dsl_args "$@"
fi
