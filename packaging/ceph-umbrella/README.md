# Ceph 21.2.0 (Umbrella) debs for the snap

The snap stages all its Ceph packages, `crimson-osd` included, from Ubuntu
packages of Ceph 21.2.0 built here. No Ubuntu or Debian archive and no PPA has
Ceph 21 yet. As of November 2026 Ubuntu stops at 20.2.4 and Debian at 20.2.5.

`debian/` is Ubuntu's Tentacle packaging (`20.2.4+ds-0ubuntu1`), carried
forward to the upstream 21.2.0 tarball:

- **Patches:**
  - `s390x-noexec` is dropped, because upstream has it.
  - `boost-resolute-fix` keeps only the hunks 21.2.0 still needs.
  - `spdk-fix-make-exe` and `python-3.14` are rebased.
  - The crimson Boost 1.90 patch is cut down to its include fix.
  - The SeaStore 512e patch from the Tentacle build is gone: 21.2.0 clamps
    the block size to 4 KiB itself.
- **Crimson:** `debian/rules` passes `WITH_CRIMSON`, the switch that Tentacle
  renamed from `WITH_SEASTAR`. `crimson-osd` ships the daemon and its tools,
  with shlib dependencies.
- **Build:** gRPC build dependencies cover the NVMe-oF gateway monitor client,
  which 21 builds by default. The option headers are generated before the
  parallel build starts, which avoids a race.
- **Install lists:** the Python bindings install `dist-info` instead of
  `egg-info`, and the `cli_api` and `nvmeof` manager modules go into
  `ceph-mgr-modules-core`.

The source is the upstream tarball, not a `+ds` repack, so the version is
`21.2.0-0ubuntu0~crimson1`.

## Building the snap

1. Build the debs. Run as root in an Ubuntu 26.04 container. On 128 cores it
   takes about 17 minutes:

   ```bash
   ./build-debs.sh /root/u21
   ```

2. Turn them into a repository, signed with the key whose public half is
   `snap/keys/0B15C94C.asc`:

   ```bash
   ./make-repo.sh /root/u21 /root/repo FB42550BD737285B930108558345C8CC0B15C94C
   ```

3. Serve the repository where snapcraft's build instance can reach it, at the
   `url` in the `package-repositories` entry of `snap/snapcraft.yaml`:

   ```bash
   python3 -m http.server 8642 --bind 10.225.23.1 --directory /root/repo
   ```

4. Pack the snap with `snapcraft pack`. The `ceph` part refuses to stage
   without `crimson-osd`.

The signing key is a throwaway made for testing. To build anywhere else,
publish the source package to a PPA instead, and point `package-repositories`
at that PPA.
