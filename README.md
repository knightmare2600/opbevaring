# opbevaring

PXE/iPXE boot for the official TrueNAS SCALE installer, with no ISO in the
loop and no rebuilt TrueNAS image: the stock kernel, initrd and live root
straight off the ISO, plus one small extra initrd that fetches the install
payload from a URL given on the kernel cmdline.

*Opbevaring* (Danish, "storage"). A sibling of
[Klargøring](https://github.com/knightmare2600/klargoring), for the same
estate and for the same reason — a vendor installer that only knows how to
start from physical media — but solved differently, see below.

## Why this exists

TrueNAS has no supported PXE install path. The ISO is a Debian `live-boot`
system whose installer (`truenas_installer`, from
[truenas/truenas-installer](https://github.com/truenas/truenas-installer))
loop-mounts the install payload from a hardcoded path —
`/cdrom/TrueNAS-SCALE.update` in 25.10.2.1 — and the only thing that ever
puts it there is `/usr/sbin/mount-cd`, which probes local block devices for
the installation medium. PXE-boot the live system and there's no medium, so
there's nothing at `/cdrom`. The community workaround is to drop to a shell
in the installer, download the `.update` by hand and symlink it into place.
This project automates exactly that, nothing more.

### Why not do it the Klargøring way

Klargøring debootstraps Debian and `apt install`s Proxmox VE on top, because
Proxmox *is* a set of packages on Debian. TrueNAS isn't: the installed system
is a sealed squashfs (`rootfs.squashfs` inside the `.update`) unpacked into
`boot-pool/ROOT/<version>` by `truenas_install`, which runs from inside the
`.update` itself. Partitioning, boot-pool creation, GRUB and the config
database are all owned by iXsystems' own installer code, so this project
reuses that code as-is rather than reimplementing any of it.

## How it works

1. iPXE boots TrueNAS's own `vmlinuz` + `initrd.img` with `boot=live
   fetch=<url>/filesystem.squashfs` — `live-boot`'s standard netboot
   mechanism. The stock initrd already has `live-boot`'s networking,
   `udhcpc`, `wget` and a full set of NIC drivers (checked in 25.10.2.1).
2. A second initrd, `opbevaring-hook.cpio`, is loaded after it. The kernel
   unpacks concatenated cpio archives into one initramfs, so this adds
   `/scripts/live-bottom/{ORDER,opbevaring}` and `/opbevaring/*` to the
   stock initramfs without modifying it. The stock initrd has no
   `/scripts/live-bottom` at all, so nothing is overwritten.
3. `live-boot` runs `/scripts/live-bottom` (supported since live-boot
   1:20180328, Debian #884355) after mounting the live root at `${rootmnt}`
   and before `switch_root`. The hook — only if `update_url=` is on the
   cmdline — copies into the live root:
   - `opbevaring-fetch.service` + `/usr/local/sbin/opbevaring-fetch`, enabled
   - a mask for `mount-cd.service` (it would otherwise mount every local
     partition read-write looking for an installation medium)
   - `After=opbevaring-fetch.service` drop-ins for `getty@`, `serial-getty@`
     and `truenas-installer.service`, so neither the console TUI nor the
     JSON-RPC server starts before the payload is in place
   - a `systemd-networkd-wait-online --any` drop-in, so a multi-NIC box with
     one cable plugged in isn't held up by its other links
4. In the booted live system, `opbevaring-fetch` mounts a tmpfs on `/cdrom`,
   downloads `update_url=` into it, optionally checks `update_sha256=`,
   checks it's a squashfs, and puts it at the path `install.py` mounts —
   read from `install.py` itself at runtime, not hardcoded, since the name
   differs between releases (`TrueNAS-SCALE.update` in 25.10.2.1,
   `TrueNAS.update` on truenas-installer's master branch).
5. From there it's the stock TrueNAS installer, unchanged.

## Repository layout

```
build/
  extract-iso.sh        pulls vmlinuz, initrd.img, filesystem.squashfs and
                         the .update off an official ISO, unmodified, into
                         <out>/<version>/ with SHA256SUMS
  build-hook-cpio.sh    builds opbevaring-hook.cpio from hook/

hook/
  live-bottom/
    ORDER               run_scripts list for /scripts/live-bottom
    opbevaring          the initramfs hook (busybox sh)
  payload/              copied into the live root by the hook
    opbevaring-fetch          fetch + verify + place the .update
    opbevaring-fetch.service
    after-fetch.conf          ordering drop-in for getty/installer units
    wait-online-any.conf      networkd-wait-online --any drop-in

examples/
  menu.ipxe             :opbevaring / :opbevaring-s stanzas
```

## Building

```
bash build/extract-iso.sh TrueNAS-SCALE-25.10.2.1.iso out
bash build/build-hook-cpio.sh out/25.10.2.1
```

No root needed for either. Needs `xorriso`, `squashfs-tools` and `cpio`.
Copy the contents of `out/<version>/` to the web server, e.g.
`bootstrap/web/truenas/opbevaring/<version>/`.

## Kernel cmdline

- `boot=live fetch=<url>/filesystem.squashfs` — **required**, stock
  `live-boot` parameters. Don't add the ISO GRUB menu's
  `toram=filesystem.squashfs`: `fetch=` already downloads into RAM.
- `update_url=<url>` — **required**. Where to fetch the `.update` payload.
  Without it the hook does nothing at all.
- `update_sha256=<hex>` — optional. Verified before the file is handed over;
  the value for each release is in the `SHA256SUMS` that `extract-iso.sh`
  writes.
- `console=tty0` / `console=ttyS0,115200n8` — as in the ISO's own GRUB menu.

## RAM

Everything lives in RAM: the live squashfs (~230 MiB for 25.10.2.1) and the
`.update` (~1.8 GiB) plus the live system's own overlay. TrueNAS's own
documented minimum of 8 GB ("at least 8 GB of RAM for basic TrueNAS
operations", [hardware guide](https://www.truenas.com/docs/scale/gettingstarted/tnhardwareguide/))
covers that comfortably; the tmpfs on `/cdrom` is capped at 4 GiB.

## Debugging

- `journalctl -u opbevaring-fetch --no-pager` — the fetch's own log. The
  console also comes up if the fetch fails (ordering only, no `Requires=`),
  so this is readable from the tty1 autologin shell.
- `ls -la /cdrom` — the payload, if it arrived.

## Status

Verified (2026-10-21, against the 25.10.2.1 ISO):

- the stock initrd's contents (no `/scripts/live-bottom`, `init-bottom/ORDER`
  is udev's, `live-boot` networking + `wget` present)
- the live root's `install.py` mounts `/cdrom/TrueNAS-SCALE.update` and is
  identical to truenas-installer master apart from that filename
- `mount-cd` in the live root is identical to scale-build master's
- the hook, run under the initrd's own busybox `sh` against a scratch
  `${rootmnt}`, writes exactly the intended files, and writes nothing
  without `update_url=`
- `opbevaring-fetch`, run with `/proc/cmdline`, `/cdrom` and the tmpfs mount
  substituted, against a local HTTP server: good download + sha256 OK;
  well-formed wrong sha256, malformed sha256, HTTP 404 and a non-squashfs
  file all rejected with the partial file removed; no `update_url=` is a
  clean no-op

**Not verified yet — needs a real boot:**

- the whole chain booting at all (QEMU needs more RAM than the build host
  has; first real test is on hardware or a VM host with ≥ 8 GiB)
- iPXE loading two initrds under UEFI on this estate's iPXE build
- `${rootmnt}` being writable at the `live-bottom` stage (it's the overlay
  root, so it is by design — not yet observed)
- the stock TUI install completing from a fetched payload

## Planned

- Unattended install: an answer TOML (`toml_url=`, the estate's
  `${site-prefix}-answer.toml` convention) driving
  `truenas_installer.install.install()` directly — disks, `truenas_admin`
  password, `post_install.network_interfaces` for the static `.19` — with
  Klargøring's `confirm-wipe` / `unattended` / `no-reboot` safety flags.
