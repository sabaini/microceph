#!/usr/bin/env bash
# Smoke test for the MicroCeph build whose OSDs are croit-flashstore-osd
# (croit ceph-rust). It launches LXD VMs with emulated NVMe disks, installs the
# snap, deploys OSDs through `microceph disk add` and checks RADOS and RBD I/O,
# an OSD service restart, an OSD crash and a disk removal. RGW and CephFS are
# not exercised: the FlashStore OSD does not serve them in this snapshot.
#
# Usage: flashstore_smoke.sh /path/to/microceph_*.snap
#
# Environment:
#   SMOKE_PREFIX       VM name prefix (default: fs-smoke)
#   SMOKE_NODES        cluster members, one VM each (default: 1)
#   SMOKE_DISKS        NVMe disks per VM (default: 4 for one node, else 1)
#   SMOKE_DISK_GIB     size of each NVMe disk (default: 8)
#   SMOKE_CPUS         vCPUs per VM (default: 4)
#   SMOKE_MEMORY       memory per VM (default: 8GiB)
#   SMOKE_CORES        flashstore.cores, cores per OSD (default: 1)
#   SMOKE_OSD_MEMORY   osd_memory_target in bytes (default: 1610612736)
#   SMOKE_IMAGE        LXD image (default: ubuntu:26.04)
#   SMOKE_SNAP_PROXY   proxy for snapd in the VMs, if the store needs one
#   SMOKE_SIDELOAD     directory of *.snap + *.assert (snapd, base) to install
#                      first, for hosts that cannot reach the snap store
#   SMOKE_INSTALL      snap install flags (default: --dangerous --devmode).
#                      FlashStore needs io_uring, which the seccomp filter of
#                      a strictly confined snap denies; see HACKING.md.
#   SMOKE_KEEP         1 = keep the VMs after the run (default: 0)
set -euo pipefail

SNAP_FILE="${1:?usage: flashstore_smoke.sh /path/to/microceph.snap}"
PREFIX="${SMOKE_PREFIX:-fs-smoke}"
NODES="${SMOKE_NODES:-1}"
if [ "${NODES}" -eq 1 ]; then
    DISKS="${SMOKE_DISKS:-4}"
else
    DISKS="${SMOKE_DISKS:-1}"
fi
DISK_GIB="${SMOKE_DISK_GIB:-8}"
CPUS="${SMOKE_CPUS:-4}"
MEMORY="${SMOKE_MEMORY:-8GiB}"
CORES="${SMOKE_CORES:-1}"
OSD_MEMORY="${SMOKE_OSD_MEMORY:-1610612736}"
IMAGE="${SMOKE_IMAGE:-ubuntu:26.04}"
SNAP_PROXY="${SMOKE_SNAP_PROXY:-}"
SIDELOAD="${SMOKE_SIDELOAD:-}"
INSTALL="${SMOKE_INSTALL:---dangerous --devmode}"
KEEP="${SMOKE_KEEP:-0}"

POOL="$(lxc profile device get default root pool)"
FIRST="${PREFIX}-1"
TOTAL_OSDS=$((NODES * DISKS))
PLUGS="block-devices hardware-observe mount-observe load-rbd microceph-support network-bind network-observe process-control dm-crypt"

log() { echo "=== $*" >&2; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
pass() { echo "PASS: $*" >&2; }

# vm NODE SCRIPT: run a bash script in the VM.
vm() {
    local node="$1"
    shift
    lxc exec "${node}" -- bash -euo pipefail -c "$*"
}

# wait_for DESCRIPTION ATTEMPTS INTERVAL COMMAND...: poll until the command succeeds.
wait_for() {
    local what="$1" attempts="$2" interval="$3"
    shift 3
    for _ in $(seq 1 "${attempts}"); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep "${interval}"
    done
    fail "timed out waiting for ${what}"
}

cleanup() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        log "state at failure"
        vm "${FIRST}" "microceph.ceph -s; microceph.ceph osd tree; snap logs -n 40 microceph.osd; snap logs -n 20 microceph.daemon" >&2 || true
    fi
    if [ "${KEEP}" = 1 ]; then
        log "keeping VMs (${PREFIX}-*)"
        return
    fi
    local n d
    for n in $(seq 1 "${NODES}"); do
        lxc delete -f "${PREFIX}-${n}" >/dev/null 2>&1 || true
        for d in $(seq 1 "${DISKS}"); do
            lxc storage volume delete "${POOL}" "${PREFIX}-${n}-nvme${d}" >/dev/null 2>&1 || true
        done
    done
}
trap cleanup EXIT

launch_vm() {
    local node="$1" d
    log "launching ${node} (${CPUS} vCPU, ${MEMORY}, ${DISKS} x ${DISK_GIB}GiB NVMe)"
    lxc init -q "${IMAGE}" "${node}" --vm -c limits.cpu="${CPUS}" -c limits.memory="${MEMORY}" -d root,size=20GiB
    for d in $(seq 1 "${DISKS}"); do
        lxc storage volume create -q "${POOL}" "${node}-nvme${d}" --type=block size="${DISK_GIB}GiB"
        lxc config device add -q "${node}" "nvme${d}" disk pool="${POOL}" source="${node}-nvme${d}" io.bus=nvme
    done
    lxc start "${node}"
}

# FlashStore needs 4096-byte LBAs without metadata. The emulated controller
# starts on 512 bytes but offers the format; a real datacenter NVMe is
# formatted the same way (`nvme format --lbaf=N`) before `microceph disk add`.
prepare_vm() {
    local node="$1" f
    wait_for "${node} agent" 120 2 lxc exec "${node}" -- true
    vm "${node}" "cloud-init status --wait >/dev/null || true"
    vm "${node}" "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq nvme-cli >/dev/null"
    # shellcheck disable=SC2016  # expanded in the VM
    vm "${node}" '
        for dev in $(lsblk -dn -o NAME,TRAN | awk "\$2 == \"nvme\" {print \$1}"); do
            if [ "$(cat /sys/class/block/${dev}/queue/logical_block_size)" != 4096 ]; then
                lbaf=$(nvme id-ns /dev/${dev} | awk "/^lbaf/ && /ms:0 / && /lbads:12 / {print \$2; exit}")
                nvme format /dev/${dev} --lbaf=${lbaf} --force >/dev/null
            fi
        done
        sleep 2
        lsblk -dn -o NAME,SIZE,LOG-SEC,TRAN | awk "\$4 == \"nvme\""'

    if [ -n "${SNAP_PROXY}" ]; then
        vm "${node}" "snap set system proxy.http=${SNAP_PROXY} proxy.https=${SNAP_PROXY}"
    fi
    if [ -n "${SIDELOAD}" ]; then
        for f in "${SIDELOAD}"/*.assert "${SIDELOAD}"/*.snap; do
            lxc file push -q "${f}" "${node}/root/sideload/$(basename "${f}")" --create-dirs
        done
        # shellcheck disable=SC2016  # expanded in the VM
        vm "${node}" 'for a in /root/sideload/*.assert; do snap ack "$a"; done
            for s in /root/sideload/snapd_*.snap /root/sideload/core*.snap; do
                [ -e "$s" ] && snap install "$s" >/dev/null
            done'
    fi
    lxc file push -q "${SNAP_FILE}" "${node}/root/microceph.snap"
    vm "${node}" "snap install ${INSTALL} /root/microceph.snap >/dev/null
        for plug in ${PLUGS}; do snap connect microceph:\${plug}; done
        snap restart microceph.daemon"
    wait_for "${node} microcephd" 60 2 vm "${node}" "(microceph status 2>&1 || true) | grep -e 'not yet initialized' -e 'MicroCeph deployment summary' >/dev/null"
}

nvme_disks() {
    # shellcheck disable=SC2016  # expanded in the VM
    vm "$1" 'lsblk -dn -o NAME,TRAN | awk "\$2 == \"nvme\" {print \"/dev/\" \$1}" | sort | tr "\n" " "'
}

osds_up() {
    vm "${FIRST}" "microceph.ceph osd stat -f json | python3 -c 'import json,sys; s=json.load(sys.stdin); sys.exit(0 if s[\"num_up_osds\"] == $1 and s[\"num_in_osds\"] == $1 and s[\"num_osds\"] == $1 else 1)'"
}

health_ok() {
    vm "${FIRST}" "microceph.ceph health | grep HEALTH_OK >/dev/null"
}

pgs_clean() {
    vm "${FIRST}" "microceph.ceph pg stat -f json | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"pg_summary\"]; states={x[\"name\"]: x[\"num\"] for x in s[\"num_pg_by_state\"]}; sys.exit(0 if s[\"num_pgs\"] > 0 and states.get(\"active+clean\") == s[\"num_pgs\"] else 1)'"
}

blob_sum() {
    vm "${FIRST}" "microceph.rados -p smoke get blob - | sha256sum | cut -d' ' -f1"
}

# ---------------------------------------------------------------- deploy

[ -f "${SNAP_FILE}" ] || fail "no such snap: ${SNAP_FILE}"
for n in $(seq 1 "${NODES}"); do
    launch_vm "${PREFIX}-${n}"
done
for n in $(seq 1 "${NODES}"); do
    prepare_vm "${PREFIX}-${n}"
done

log "the snap ships croit-flashstore-osd and no ceph-osd"
vm "${FIRST}" "test -x /snap/microceph/current/bin/croit-flashstore-osd
    test -x /snap/microceph/current/bin/croit-flashstore-tool
    test ! -e /snap/microceph/current/bin/ceph-osd
    cat /snap/microceph/current/share/ceph-rust/VERSION"
pass "snap content"

log "bootstrapping the cluster on ${FIRST}"
vm "${FIRST}" "microceph cluster bootstrap"
for n in $(seq 2 "${NODES}"); do
    node="${PREFIX}-${n}"
    token="$(vm "${FIRST}" "microceph cluster add ${node}")"
    vm "${node}" "microceph cluster join ${token}"
done
wait_for "mon quorum" 60 2 vm "${FIRST}" "microceph.ceph -s"
vm "${FIRST}" "microceph.ceph config set osd osd_memory_target ${OSD_MEMORY}"

log "snap options: invalid values are refused, lab values are set"
if vm "${FIRST}" "snap set microceph flashstore.cores=many" 2>/dev/null; then
    fail "flashstore.cores=many was accepted"
fi
# The emulated NVMe reports a volatile write cache; real PLP drives need no allow-vwc.
for n in $(seq 1 "${NODES}"); do
    vm "${PREFIX}-${n}" "snap set microceph flashstore.cores=${CORES} flashstore.allow-vwc=true"
done
pass "snap options"

log "unsupported layouts are refused"
out="$(vm "${FIRST}" "microceph disk add loop,1G,1 2>&1 || true")"
echo "${out}" | grep -q "loop file OSDs are not supported with FlashStore" || fail "loop OSD not refused: ${out}"
first_disk="$(nvme_disks "${FIRST}" | cut -d' ' -f1)"
out="$(vm "${FIRST}" "microceph disk add ${first_disk} --encrypt 2>&1 || true")"
echo "${out}" | grep -q "encryption is not supported with FlashStore" || fail "encrypted OSD not refused: ${out}"
pass "loop and encrypted OSDs refused"

# On one node the last disk stays back for the add/remove test.
initial_osds="${TOTAL_OSDS}"
spare=""
if [ "${NODES}" -eq 1 ] && [ "${DISKS}" -ge 4 ]; then
    initial_osds=$((TOTAL_OSDS - 1))
fi
for n in $(seq 1 "${NODES}"); do
    node="${PREFIX}-${n}"
    disks="$(nvme_disks "${node}")"
    if [ "${initial_osds}" -ne "${TOTAL_OSDS}" ]; then
        spare="$(echo "${disks}" | awk '{print $NF}')"
        disks="$(echo "${disks}" | awk '{NF--; print}')"
    fi
    log "${node}: microceph disk add ${disks}"
    # shellcheck disable=SC2086
    vm "${node}" "microceph disk add ${disks}"
done
wait_for "${initial_osds} OSDs up and in" 90 2 osds_up "${initial_osds}"
pass "${initial_osds} OSDs up and in"

log "every OSD is a croit-flashstore-osd process"
for n in $(seq 1 "${NODES}"); do
    vm "${PREFIX}-${n}" "if pgrep -x ceph-osd >/dev/null; then echo 'a ceph-osd process is running'; exit 1; fi
        pgrep -af '^croit-flashstore-osd run' | sed 's/^/  /'"
done
vm "${FIRST}" "microceph.ceph versions | python3 -c '
import json, sys
osd = json.load(sys.stdin)[\"osd\"]
assert len(osd) == 1 and sum(osd.values()) == ${initial_osds}, osd
assert \"croit-flashstore-osd\" in list(osd)[0], osd
print(\"  \" + list(osd)[0])'"
vm "${FIRST}" "microceph disk list; microceph.flashstore-tool list"
pass "OSDs are FlashStore"

# ---------------------------------------------------------------- RADOS

log "RADOS: pool, object round trip, bench"
vm "${FIRST}" "microceph.ceph osd pool create smoke 32 >/dev/null 2>&1
    microceph.ceph osd pool application enable smoke rbd >/dev/null 2>&1"
wait_for "PGs active+clean" 90 2 pgs_clean
vm "${FIRST}" "head -c 33554432 /dev/urandom > /root/blob"
want="$(vm "${FIRST}" "sha256sum /root/blob | cut -d' ' -f1")"
vm "${FIRST}" "cat /root/blob | microceph.rados -p smoke put blob -"
[ "$(blob_sum)" = "${want}" ] || fail "RADOS object differs after the round trip"
vm "${FIRST}" "microceph.rados -p smoke setomapval blob key value
    microceph.rados -p smoke listomapkeys blob | grep -x key >/dev/null
    microceph.rados -p smoke getomapval blob key | grep value >/dev/null
    microceph.rados -p smoke setxattr blob user.smoke attr
    test \"\$(microceph.rados -p smoke getxattr blob user.smoke)\" = attr
    microceph.rados -p smoke bench 10 write --no-cleanup 2>&1 | grep -E 'Bandwidth \(MB/sec\)|Average IOPS' | sed 's/^/  write /'
    microceph.rados -p smoke bench 5 seq 2>&1 | grep -E 'Bandwidth \(MB/sec\)|Average IOPS' | sed 's/^/  read  /'
    microceph.rados -p smoke cleanup >/dev/null 2>&1"
pass "RADOS object, omap, xattr, bench"

# ------------------------------------------------------------------ RBD

log "RBD: import/export, snapshot, clone"
vm "${FIRST}" "cat /root/blob | microceph.rbd import - smoke/img >/dev/null 2>&1
    test \"\$(microceph.rbd export smoke/img - 2>/dev/null | sha256sum | cut -d' ' -f1)\" = ${want}
    microceph.rbd snap create smoke/img@s1 2>/dev/null
    microceph.rbd snap protect smoke/img@s1
    microceph.rbd bench --io-type write --io-size 64K --io-total 16M smoke/img >/dev/null 2>&1
    test \"\$(microceph.rbd export smoke/img - 2>/dev/null | sha256sum | cut -d' ' -f1)\" != ${want}
    test \"\$(microceph.rbd export smoke/img@s1 - 2>/dev/null | sha256sum | cut -d' ' -f1)\" = ${want}
    microceph.rbd clone smoke/img@s1 smoke/clone
    test \"\$(microceph.rbd export smoke/clone - 2>/dev/null | sha256sum | cut -d' ' -f1)\" = ${want}
    microceph.rbd bench --io-type write --io-size 4K --io-total 16M smoke/clone 2>&1 | tail -1 | sed 's/^/  4K write /'"
pass "RBD import/export, snapshot, clone"

log "RBD: kernel client"
if vm "${FIRST}" "modprobe rbd" 2>/dev/null; then
    vm "${FIRST}" "microceph.rbd create --size 512M smoke/kimg
        dev=\$(microceph.rbd map smoke/kimg)
        mkfs.ext4 -q \$dev
        mkdir -p /mnt/kimg && mount \$dev /mnt/kimg
        cp /root/blob /mnt/kimg/blob && sync
        umount /mnt/kimg && mount \$dev /mnt/kimg
        test \"\$(sha256sum /mnt/kimg/blob | cut -d' ' -f1)\" = ${want}
        umount /mnt/kimg
        microceph.rbd unmap \$dev"
    pass "krbd map, ext4, data intact after remount"
else
    log "SKIP: no rbd kernel module in this image"
fi

# ----------------------------------------------------------- resilience

log "restart of the osd service: stores are remounted, data intact"
vm "${FIRST}" "snap restart microceph.osd"
wait_for "${initial_osds} OSDs up after the restart" 90 2 osds_up "${initial_osds}"
wait_for "HEALTH_OK after the restart" 120 2 health_ok
[ "$(blob_sum)" = "${want}" ] || fail "RADOS object differs after the OSD restart"
pass "OSD service restart"

log "OSD crash: data stays readable, a reload brings the OSD back"
victim="$(vm "${FIRST}" "ls /var/snap/microceph/common/data/osd | sort -V | sed -n '1s/ceph-//p'")"
vm "${FIRST}" "pkill -9 -f 'croit-flashstore-osd .* --id ${victim}\$'"
wait_for "osd.${victim} marked down" 90 2 vm "${FIRST}" "microceph.ceph osd tree down | grep -w osd.${victim} >/dev/null"
[ "$(blob_sum)" = "${want}" ] || fail "RADOS object unreadable with osd.${victim} down"
vm "${FIRST}" "cat /root/blob | microceph.rados -p smoke put blob-degraded -"
vm "${FIRST}" "snap restart --reload microceph.osd"
wait_for "osd.${victim} back up" 90 2 osds_up "${initial_osds}"
wait_for "HEALTH_OK after recovery" 150 2 health_ok
test "$(vm "${FIRST}" "microceph.rados -p smoke get blob-degraded - | sha256sum | cut -d' ' -f1")" = "${want}" ||
    fail "object written while degraded differs after recovery"
pass "OSD crash and recovery"

# -------------------------------------------------------- add and remove

if [ -n "${spare}" ]; then
    log "adding a fourth OSD on ${spare}, then removing osd.${victim}"
    vm "${FIRST}" "microceph disk add ${spare}"
    wait_for "${TOTAL_OSDS} OSDs up and in" 90 2 osds_up "${TOTAL_OSDS}"
    wait_for "HEALTH_OK after the add" 240 2 health_ok
    victim_dev="$(vm "${FIRST}" "python3 -c 'import json; print(json.load(open(\"/var/snap/microceph/common/data/osd/ceph-${victim}/croit-flashstore-osd\"))[\"dev\"].split(\":\", 1)[1])'")"
    vm "${FIRST}" "microceph disk remove osd.${victim}"
    wait_for "$((TOTAL_OSDS - 1)) OSDs after the removal" 90 2 osds_up "$((TOTAL_OSDS - 1))"
    vm "${FIRST}" "if pgrep -f 'croit-flashstore-osd .* --id ${victim}\$' >/dev/null; then echo 'osd.${victim} still runs'; exit 1; fi
        test ! -e /var/snap/microceph/common/data/osd/ceph-${victim}
        if microceph.ceph osd tree | grep -w osd.${victim} >/dev/null; then echo 'osd.${victim} still in the CRUSH tree'; exit 1; fi"
    wait_for "HEALTH_OK after the removal" 240 2 health_ok
    [ "$(blob_sum)" = "${want}" ] || fail "RADOS object differs after the OSD removal"
    pass "disk remove"

    log "re-adding ${victim_dev} with --wipe"
    vm "${FIRST}" "microceph disk add ${victim_dev} --wipe"
    wait_for "${TOTAL_OSDS} OSDs up and in again" 90 2 osds_up "${TOTAL_OSDS}"
    wait_for "HEALTH_OK after the re-add" 240 2 health_ok
    [ "$(blob_sum)" = "${want}" ] || fail "RADOS object differs after the re-add"
    pass "disk add --wipe on a used device"
fi

log "final state"
vm "${FIRST}" "microceph.ceph -s; microceph.ceph osd tree; microceph.ceph versions; microceph status"
pass "FlashStore smoke test: ${NODES} node(s), ${TOTAL_OSDS} OSD(s)"
