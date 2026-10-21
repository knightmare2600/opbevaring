#!/bin/bash
# Extracts the PXE-servable pieces of an official TrueNAS SCALE ISO, unmodified:
#
#   <output-dir>/<version>/vmlinuz
#   <output-dir>/<version>/initrd.img
#   <output-dir>/<version>/filesystem.squashfs
#   <output-dir>/<version>/<name>.update       (whatever the ISO calls it)
#   <output-dir>/<version>/SHA256SUMS
#
# <version> is read from the live root's own /etc/version, not parsed out of the ISO filename.
# No root needed. Needs xorriso and squashfs-tools.
#
# Usage: bash build/extract-iso.sh TrueNAS-SCALE-<version>.iso <output-dir>
set -euo pipefail

iso=${1:?usage: $0 <truenas.iso> <output-dir>}
out=${2:?usage: $0 <truenas.iso> <output-dir>}

for tool in xorriso unsquashfs sha256sum
do
  command -v "${tool}" > /dev/null || { echo "missing: ${tool}" >&2; exit 1; }
done

update=$(xorriso -osirrox on -indev "${iso}" -find / -maxdepth 1 -name '*.update' 2> /dev/null | tr -d "'")
if [ -z "${update}" ]
then
  echo "no *.update payload found at the root of ${iso}" >&2
  exit 1
fi

staging="${out}/.staging"
rm -rf "${staging}"
mkdir -p "${staging}"

xorriso -osirrox on -indev "${iso}" \
  -extract /vmlinuz "${staging}/vmlinuz" \
  -extract /initrd.img "${staging}/initrd.img" \
  -extract /live/filesystem.squashfs "${staging}/filesystem.squashfs" \
  -extract "${update}" "${staging}/${update#/}"

version=$(unsquashfs -cat "${staging}/filesystem.squashfs" etc/version)
dest="${out}/${version}"
rm -rf "${dest}"
mv "${staging}" "${dest}"
chmod 0644 "${dest}"/*

(cd "${dest}" && sha256sum vmlinuz initrd.img filesystem.squashfs "${update#/}" > SHA256SUMS)

echo "TrueNAS ${version} extracted to ${dest}:"
cat "${dest}/SHA256SUMS"
