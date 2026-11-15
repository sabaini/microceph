#!/bin/bash
# Publish the debs from build-debs.sh as a signed apt repository, laid out
# for the package-repositories entry in snap/snapcraft.yaml.
#
# Usage: make-repo.sh DEBDIR REPODIR KEY
#   DEBDIR   directory holding the .debs
#   REPODIR  directory to (re)create the repository in; serve it over HTTP
#   KEY      GnuPG key to sign with, from the keyring in $GNUPGHOME
set -euo pipefail

debdir=$(cd "${1:?usage: make-repo.sh DEBDIR REPODIR KEY}" && pwd)
repodir=${2:?usage: make-repo.sh DEBDIR REPODIR KEY}
key=${3:?usage: make-repo.sh DEBDIR REPODIR KEY}
suite=resolute
arch=$(dpkg --print-architecture)

rm -rf "${repodir}"
mkdir -p "${repodir}/pool" "${repodir}/dists/${suite}/main/binary-${arch}"
cp "${debdir}"/*.deb "${repodir}/pool/"
cd "${repodir}"

apt-ftparchive packages pool > "dists/${suite}/main/binary-${arch}/Packages"
gzip -9 --keep "dists/${suite}/main/binary-${arch}/Packages"

# The Release file must not list itself, so write it outside the tree first.
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=microceph-crimson \
    -o APT::FTPArchive::Release::Suite="${suite}" \
    -o APT::FTPArchive::Release::Codename="${suite}" \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Architectures="${arch}" \
    release "dists/${suite}" > Release.tmp
mv Release.tmp "dists/${suite}/Release"
gpg --batch --yes --local-user "${key}" --clearsign \
    --output "dists/${suite}/InRelease" "dists/${suite}/Release"
gpg --batch --yes --local-user "${key}" --armor --detach-sign \
    --output "dists/${suite}/Release.gpg" "dists/${suite}/Release"
