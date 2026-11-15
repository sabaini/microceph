# Ceph 21.2.0 (Umbrella) debs for the snap

The snap stages all its Ceph packages, `crimson-osd` included, from Ubuntu
packages of Ceph 21.2.0 built from `debian/` here and published in
[ppa:peter-sabaini/ceph-umbrella-crimson](https://launchpad.net/~peter-sabaini/+archive/ubuntu/ceph-umbrella-crimson).
No Ubuntu or Debian archive has Ceph 21 yet. As of November 2026 Ubuntu stops
at 20.2.4 and Debian at 20.2.5.

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
`21.2.0-0ubuntu0~crimson1~ppa1`.

## Publishing to the PPA

Build a signed source package from the upstream tarball and upload it. The
`.orig.tar.gz` must be the one `build-debs.sh` verifies:

```bash
tar -xzf ceph_21.2.0.orig.tar.gz
cd ceph-21.2.0
rm -rf debian
cp -a /path/to/packaging/ceph-umbrella/debian debian
dpkg-buildpackage -S -sa -d
cd ..
dput ppa:peter-sabaini/ceph-umbrella-crimson ceph_21.2.0-0ubuntu0~crimson1~ppa1_source.changes
```

Bump the `~ppaN` suffix in `debian/changelog` for every new upload. Launchpad's
amd64 builders take about two and a quarter hours.

## Building the snap

`snapcraft pack` pulls the packages from the PPA. The `ceph` part refuses to
stage without `crimson-osd`.

## Building the debs locally

To test packaging changes before uploading, build the binary packages as root
in an Ubuntu 26.04 container. On 128 cores this takes about 17 minutes:

```bash
./build-debs.sh /root/u21
```

To build the snap from such a local build, serve the debs as a signed apt
repository (`apt-ftparchive`) and add it to `package-repositories` in
`snap/snapcraft.yaml`, with the signing key in `snap/keys/`.
