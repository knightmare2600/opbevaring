#!/bin/bash
# Builds opbevaring-hook.cpio: a small, uncompressed newc cpio that iPXE loads as a second
# initrd after TrueNAS's own initrd.img. The kernel unpacks concatenated cpio archives into
# one initramfs, so its contents simply appear alongside the stock initrd's:
#
#   /scripts/live-bottom/ORDER         initramfs-tools' run_scripts only runs what's listed here
#   /scripts/live-bottom/opbevaring    the hook itself (see hook/live-bottom/opbevaring)
#   /opbevaring/*                      files the hook copies into the live root
#
# No root needed -- ownership is forced to 0:0 inside the archive.
#
# Usage: bash build/build-hook-cpio.sh <output-dir>
set -euo pipefail

out=${1:?usage: $0 <output-dir>}
repo=$(cd "$(dirname "$0")/.." && pwd)

staging=$(mktemp -d)
trap 'rm -rf "${staging}"' EXIT

install -D -m 0644 "${repo}/hook/live-bottom/ORDER" "${staging}/scripts/live-bottom/ORDER"
install -D -m 0755 "${repo}/hook/live-bottom/opbevaring" "${staging}/scripts/live-bottom/opbevaring"
install -D -m 0755 "${repo}/hook/payload/opbevaring-fetch" "${staging}/opbevaring/opbevaring-fetch"
for f in opbevaring-fetch.service after-fetch.conf wait-online-any.conf
do
  install -D -m 0644 "${repo}/hook/payload/${f}" "${staging}/opbevaring/${f}"
done

mkdir -p "${out}"
(cd "${staging}" && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc -R 0:0) > "${out}/opbevaring-hook.cpio"

echo "Built ${out}/opbevaring-hook.cpio:"
cpio --quiet -itv < "${out}/opbevaring-hook.cpio"
