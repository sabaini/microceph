#!/bin/bash
# Build Ubuntu packages of Ceph 21.2.0 (Umbrella) with crimson enabled.
#
# Neither Ubuntu nor Debian package Ceph 21 yet. debian/ here is Ubuntu's
# Tentacle packaging (20.2.4+ds-0ubuntu1) carried forward to 21.2.0: patches
# refreshed or dropped where upstream has them, build dependencies and
# install lists updated, and crimson-osd actually built and packaged.
#
# Run as root on Ubuntu 26.04. Build dependencies are installed with apt.
#
# Usage: build-debs.sh WORKDIR
#   WORKDIR  directory for the tarball and source tree; the .debs land in it
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
workdir=${1:?usage: build-debs.sh WORKDIR}
version=21.2.0
url="https://download.ceph.com/tarballs/ceph-${version}.tar.gz"
# download.ceph.com publishes no checksums; this is the tarball whose
# src/.git_version matches the v21.2.0 tag (b060042deb05d33e6cc358970cfb8221240bcf3e).
sha256=82d3c02609161bde130c7c41c33c5f8b3b59185cdea77e7929bbde2cbc66e385

mkdir -p "${workdir}"
cd "${workdir}"
orig="ceph_${version}.orig.tar.gz"
if [ ! -f "${orig}" ]; then
    curl -fsSL -o "${orig}.tmp" "${url}"
    mv "${orig}.tmp" "${orig}"
fi
echo "${sha256}  ${orig}" | sha256sum -c -

rm -rf "ceph-${version}"
tar -xzf "${orig}"
cd "ceph-${version}"
# The tarball carries upstream's own packaging, which differs from Ubuntu's.
rm -rf debian
cp -a "${here}/debian" debian

apt-get build-dep --yes --no-install-recommends ./
dpkg-source --before-build .

# debian/rules caps the build at four jobs unless told otherwise. Crimson
# translation units need about 3 GiB each, so size the build by memory too.
mem_jobs=$(awk '/MemTotal/ { j = int($2 / 1024 / 1024 / 3); print (j < 1) ? 1 : j }' /proc/meminfo)
cpu_jobs=$(nproc)
jobs=$(( mem_jobs < cpu_jobs ? mem_jobs : cpu_jobs ))

DEB_BUILD_OPTIONS="nocheck noddebs parallel=${jobs}" \
DEB_BUILD_PROFILES="pkg.ceph.unleashed" \
    dpkg-buildpackage -b -uc -us

contents=$(dpkg-deb -c ../crimson-osd_*.deb)
if ! grep -q '/usr/bin/crimson-osd$' <<< "${contents}"; then
    echo "crimson-osd package does not contain the daemon" >&2
    exit 1
fi
