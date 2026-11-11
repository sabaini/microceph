# MicroCeph Hacking Guide

Wait! No-one's "hacking" anything. The aim of this document is to enable new developers/users get familiarised with the build tools and MicroCeph codebase so that they can build and contribute to the [MicroCeph Codebase](https://github.com/canonical/microceph).

## Table of Contents

1. [⚡️ Introduction to snaps](#⚡️-introduction-to-snaps)
2. [🧰 Tools](#🧰-tools)
3. [📖 References](#📖-references)
4. [🏭 Build Guide](#🏭-build-guide)
5. [👍 Unit-Testing](#👍-unit-testing)
6. [DB Schema Updates](#db-schema-updates)
7. [RGW placement (in development)](#rgw-placement-in-development)
8. [FlashStore OSDs (croit ceph-rust, experimental)](#flashstore-osds-croit-ceph-rust-experimental)

## ⚡️ Introduction to snaps

> A [snap](https://snapcraft.io/about) is a bundle of an app and its dependencies that works without modification across Linux distributions.

Apart from being a self-contained artifact, being a snap enables MicroCeph to be isolated from host and provide a clean and consistent building, installing and cleanup experience.

The microceph snap packages all the required ceph-binaries, [dqlite](https://dqlite.io/) and a small management daemon (microcephd) which ties all of this together. Using the light-weight distributed dqlite layer, MicroCeph enables orchestration of a ceph cluster in a centralised and easy to use manner.

## 🧰 Tools

Snaps are built and published using another snap called [snapcraft](https://snapcraft.io/snapcraft). It uses [lxd](https://snapcraft.io/lxd) to pull dependencies and build an artifact completely isolated from the host system. This makes it easier for developers to work on MicroCeph without polluting their host system with unwanted dependencies.
You can install snapcraft and lxd using snap tool.

```bash
sudo snap install snapcraft --classic
sudo snap install lxd
```

> [!NOTE]
> For a detailed how-to-use snapcraft tool guide, check-out [Snap-Tutorials](https://snapcraft.io/docs/snap-tutorials)

## 📖 References

The MicroCeph codebase resides inside the microceph sub-directory of the repo. This subdir is neatly organised into parts which make up the whole of MicroCeph. Below is a brief description of what can be found in each of those parts for reference.

### Sub Directories

1. **[api](/microceph/api)**

    Contains files related to the internal REST APIs which the microceph client uses to communicate to the microceph daemon. It also contains a types subdir which has necessary data structures for the APIs.

2. **[ceph](/microceph/ceph)**

    Contains files directly related to ceph orchestration. This includes code for ceph cluster configuration, service orchestration etc.

3. **[client](/microceph/client)**

    Contains REST client code which is used by microceph CLI for interacting with microceph daemon.

4. **[cmd](/microceph/cmd)**

    Contains microceph CLI commands written with [Cobra Commands](https://github.com/spf13/cobra)

5. **[common](/microceph/common)**

    Contains common code

6. **[database](/microceph/database)**

    Contains DQlite schema and migration definitions along with generated mappers for DB interfacing.

7. **[mocks](/microceph/mocks)**

    Contains mock definitions for unit testing

## 🏭 Build Guide

Building MicroCeph is as easy as a snap!

```bash
# v for verbose output of the build process.
snapcraft -v
...
Creating snap package
...
Created snap package microceph_0+git.ac1da26_amd64.snap
```

The newly created .snap artifact can then be installed as

```bash
# Dangerous flag for locally built snap
sudo snap install --dangerous microceph_*.snap
```

```bash
# Locally built snaps do no auto-connect the available plugs on install, they can be connected manually using;
sudo snap connect microceph:block-devices
sudo snap connect microceph:hardware-observe
sudo snap connect microceph:mount-observe
sudo snap connect microceph:load-rbd
sudo snap connect microceph:microceph-support
sudo snap connect microceph:network-bind
sudo snap connect microceph:process-control
sudo snap connect microceph:dm-crypt
sudo snap restart microceph.daemon

```

## 👍 Unit-Testing

The MicroCeph [Makefile](/microceph/Makefile) has targets for running unit tests and lint checks. However, you will need the following packages or tool to run them locally.

```bash
# Add general requirements
sudo apt install gcc make shellcheck

# Add libdqlite-dev, required for building microceph
# you may need a specific version such as libdqlite1.18-dev
sudo add-apt-repository ppa:dqlite/dev -y
sudo apt install -y libdqlite-dev

# Install go and export the binary to PATH
sudo snap install go --classic
export PATH=$PATH:$HOME/go/bin
```

Once you install the prerequisite, you can run unit tests and lint checks as follows:

```bash
cd microceph

# Run unit tests
make check-unit

# Run static checks
make check-static
```

## DB Schema Updates

MicroCeph uses [lxd-generate](https://pkg.go.dev/github.com/canonical/lxd/lxd/db/generate) to auto-generate database mapper code (SQL statements and Go CRUD functions) from struct definitions. When adding a new database entity or modifying `//go:generate` directives, you need to regenerate the corresponding `.mapper.go` file.

### Installing lxd-generate

Install the generator matching the version of `github.com/canonical/lxd` in `go.mod`:

```bash
# Check the pinned version
grep 'canonical/lxd ' go.mod

# Install it (replace the version hash as needed)
go install github.com/canonical/lxd/lxd/db/generate@v0.0.0-20241106165613-4aab50ec18c3

# The binary installs as "generate" — create a symlink with the expected name
ln -s ~/go/bin/generate ~/go/bin/lxd-generate

# Ensure ~/go/bin is in your PATH
export PATH="$HOME/go/bin:$PATH"
```

### Running the generator

Target the specific file:

```bash
cd microceph
go generate ./database/host_tag.go
```

This reads the `//go:generate mapper` directives in the source file and produces the corresponding `.mapper.go` file with SQL statements and Go functions.

## RGW placement (in development)

MicroCeph can place the RADOS Gateway (RGW) on cluster members from the placement policy sent to `PUT /1.0/placement`. Each member entry in that policy can carry an `rgw` object. This is still being built, so it has no page in the published documentation yet. Until it does, this section is the reference. Keep it current when you change the behaviour.

### The `rgw` object

`mode` is required by the placement API and is always `reconcile`.

```json
{
  "mode": "reconcile",
  "members": {
    "node-a": { "rgw": { "enabled": true, "ssl": false, "port": 8080 } },
    "node-b": { "rgw": { "enabled": true, "ssl": true, "ssl_certificate": "<base64 PEM>", "ssl_private_key": "<base64 PEM>" } },
    "node-c": { "rgw": { "enabled": false } }
  }
}
```

| Field | Meaning |
|---|---|
| `enabled` | Required. `true` runs a gateway on the member, `false` removes it. |
| `ssl` | Required when `enabled` is true. TLS is never guessed from the certificate fields. |
| `port` | Plaintext port. Defaults to 80 without TLS. With TLS it is optional: set it to serve plaintext as well. |
| `ssl_port` | TLS port. Defaults to 443. |
| `ssl_certificate`, `ssl_private_key` | Base64 PEM. Write-only: sent to the member, never stored in the database, never returned by `GET`. |

### Rules that hold today

- **A member with no `rgw` object is not touched.** Nothing reconciles between `PUT`s. An empty policy and `DELETE /1.0/placement` stop no gateway.
- **The shape is strict.** A bare boolean `rgw`, a missing `enabled` or `ssl`, a certificate without its key, and the same port for both listeners are all rejected before anything changes.
- **`ssl: true` without a certificate and key means reuse.** The member first recovers any pending RGW update, then reuses the locally configured pair. If it has no usable pair the request fails. It never falls back to plaintext.
- **Additions come before removals.** Within one request every gateway addition is tried, then the removals. If any addition fails, all removals wait, so a migration never stops the old gateway before the new one serves. Gateways can scale to zero.
- **`rgw_frontend` in `GET /1.0/placement` is the last applied setting,** read from the `rgw_frontends` table. It is not a health check. If it is absent, the setting is unknown, not plaintext.
- **One owner per member.** Do not use `microceph enable rgw` or `microceph disable rgw` on a member whose policy entry has an `rgw` object. The next `PUT` applies the policy again without warning. `microceph certificate set rgw` is safe and never changes the policy.
- **Applying is safe to repeat after recovery.** An unchanged running configuration needs no restart unless a pending update must first be recovered. See [Defer certificate activation](docs/snap/how-to/rotate-rgw-tls-certificate.rst#defer-certificate-activation) in the certificate rotation guide for the user-visible restart behaviour.
- **RGW placement and certificate updates have a 7 minute member request budget:** up to 2 minutes each for recovery, requested activation and verified rollback, plus 1 minute for overhead. Other service placement timeouts remain unchanged. This is not a guarantee for an entire multi-member apply: placement PUT execution has a separate ten-minute aggregate server deadline.

### What a `PUT` returns for RGW

| Status | Meaning |
|---|---|
| 200 | Stored, and every gateway change succeeded. |
| 400 | Invalid `rgw` object or certificate, unknown member, or a target member that does not list `placement-rgw` in `GET /1.0/cluster/capabilities`. |
| 409 | Another apply is in progress. |
| 500 | A gateway could not be enabled or disabled. The message names each member and keeps any other refusal from the same request. |
| 503 | The cluster is partly refreshed. |

### On the member

| File | Role |
|---|---|
| `/var/snap/microceph/current/conf/radosgw.conf` | Once the file exists, only the `rgw frontends` line is rewritten, so a monitor list refresh made at the same time survives. The first enable writes the whole file. |
| `/var/snap/microceph/current/conf/radosgw.conf.pending` | Holds the previous config and service-active state while a change is in flight, including a deferred certificate update. Successful recovery rebases the rollback target to the activated config before clearing the marker. Manual restarts do not clear it. |
| `/var/snap/microceph/common/rgw-tls/<hash>/server.crt`, `server.key` | One directory per certificate and key pair, named by a hash of both. The config switches to a directory only once both files are complete. Recovery alone does not prune. Old directories are removed after a successful placement database commit, a confirmed rollback, or a completed certificate request, including an identical deferred request satisfied by recovery. A different deferred certificate request retains its rollback generation. |

### Upgrades

- A policy stored while `rgw` was still a boolean cannot be decoded. `GET /1.0/placement` returns 500 until the next `PUT` or `DELETE` replaces it.
- A TLS gateway set up by an earlier revision keeps its pair in `server.crt` and `server.key`. The first apply that touches it moves the pair into a hashed `rgw-tls/` directory and restarts the gateway once.
- A gateway that was running before this revision has no `rgw_frontends` row until its first apply.

### Where the code lives

All paths are under `microceph/` unless noted.

| Path | Role |
|---|---|
| `api/types/placement.go` | The `rgw` object and its validation. |
| `ceph/placement.go` | The cluster pass: order, held removals, error classes. |
| `ceph/services_placement_rgw.go`, `ceph/rgw.go` | Applying on one member: TLS pair, readiness, rollback, disable. |
| `database/rgw_frontend.go` | The `rgw_frontends` table. |
| `tests/robot/rgw-placement-tests`, `tests/robot/rgw-placement-multivm-tests` (repository root) | The end-to-end suites. |

## FlashStore OSDs (croit ceph-rust, experimental)

This branch builds a MicroCeph whose OSDs run on [croit ceph-rust](https://github.com/croit/ceph-rust), a Rust implementation of Ceph services published as a read-only source snapshot (public preview, not for production data). `croit-flashstore-osd` replaces `ceph-osd` and BlueStore. Everything else is classic Ceph from the Tentacle packages, because the snapshot has nothing to replace it with:

- Monitors and managers: ceph-rust has none and expects classic ones.
- `ceph`, `rbd`, `rados` and the other client tools: the snapshot holds the Rust client crates but not the crate that builds the drop-in `librados.so.2` / `librbd.so.1`.
- RGW and CephFS are not tested on FlashStore OSDs. ceph-rust lists both as later deliverables.

The snapshot's `main` branch tracks Ceph v21.2.0, and its v20.2.4 branch is not published. The OSD built from `main` joins the Tentacle cluster (it accepts `require_osd_release` from Pacific on) and reports itself as `21.2.0 umbrella` in `ceph versions`. Because the monitors are then the older daemons, Ceph will raise `DAEMON_OLD_VERSION` after `mon_warn_older_version_delay` (one week).

### What an operator needs

- One whole NVMe namespace per OSD, formatted to 4096-byte LBAs without metadata (`nvme format /dev/nvmeXnY --lbaf=<index of the 4096+0 format>`), with power-loss protection.
- Linux 5.19 or newer with io_uring enabled.
- The snap installed with `--devmode`, see [Confinement](#confinement).

`microceph disk add /dev/nvmeXnY` then works as usual. Two snap options tune it:

| Option | Meaning |
|---|---|
| `flashstore.cores` | Cores each OSD runs on, also the store shards of OSDs added later. Unset: the daemon's default (up to 8). The OSD service reads it at start. |
| `flashstore.allow-vwc` | `true` accepts a device with a volatile write cache when a disk is added. Lab only (emulated NVMe in a VM): such a device has no power-loss protection. |

Refused with an error, because FlashStore cannot serve them: loop file OSDs (`loop,4G,3`), WAL/DB devices (also `--wal-match` / `--db-match`) and `--encrypt`. The OSD service skips an OSD directory that `croit-flashstore-tool` did not prepare, such as a BlueStore OSD of a classic MicroCeph: this snap ships no `ceph-osd`.

`microceph.flashstore-tool` is `croit-flashstore-tool`, for `list`, `inspect --id N`, `fsck --id N` and the like.

### Confinement

FlashStore does all network and disk I/O through io_uring. The seccomp filter of a strictly confined snap denies `io_uring_setup`, `io_uring_enter` and `io_uring_register`, and no interface MicroCeph plugs allows them (snapd 2.78). Under strict confinement `microceph disk add` therefore fails with `kernel store: io_uring refused`. Until snapd allows the three calls, for example in `microceph-support`, install this build with `--devmode`.

With the three calls added to the seccomp profiles of the `daemon`, `osd` and `flashstore-tool` apps by hand, the OSDs run under strict confinement. The one AppArmor rule missing then is read access to `/proc/sys/net/ipv4/tcp_rmem`, which the `network-observe` plug of the `osd` app now provides. Reads of `/proc/irq/*/smp_affinity_list` stay denied; they only feed a host-tuning warning.

### Where the code lives

| Path | Role |
|---|---|
| `snap/snapcraft.yaml`, part `ceph-rust` | Builds `croit-flashstore-osd` and `croit-flashstore-tool` from a pinned snapshot commit: kernel TCP and kernel NVMe, no SPDK, no RDMA, no lab backends. |
| `snapcraft/commands/daemon.start` | Sets `MICROCEPH_OSD_BACKEND=flashstore` for `microcephd`. Unset, the Go code deploys BlueStore as before. |
| `microceph/ceph/osd_flashstore.go` | Backend switch, `croit-flashstore-tool prepare` in place of `ceph-osd --mkfs`, the refusals above. `prepare` creates the OSD's uuid and cephx key and registers them with the monitors, so MicroCeph generates neither. |
| `snapcraft/commands/osd.start` | Runs one foreground `croit-flashstore-osd run ... --id N` per prepared OSD. `--id` stays last: `microcephd` finds the process of an OSD by it. |
| `snap/hooks/configure` | Validates the `flashstore.*` options. |
| `tests/scripts/flashstore_smoke.sh` | End-to-end smoke test in LXD VMs with emulated NVMe disks. |

### Smoke test

```bash
tests/scripts/flashstore_smoke.sh /path/to/microceph_*.snap                # one VM, four OSDs
SMOKE_NODES=3 tests/scripts/flashstore_smoke.sh /path/to/microceph_*.snap  # three VMs, one OSD each
```

It formats the emulated namespaces to 4096-byte LBAs, deploys the OSDs through `microceph disk add` and checks RADOS (object, omap, xattr, bench), RBD (import/export, snapshot, clone, kernel client), a restart of the OSD service, a killed OSD and, on one VM, `disk remove` and `disk add --wipe`. The variables at the top of the script set VM size, the snapd proxy and a directory of base snaps to side-load.
