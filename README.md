# opbevaring

PXE/iPXE boot for the official TrueNAS SCALE installer, with no ISO in the
loop and no rebuilt TrueNAS image: the stock kernel, initrd and live root
straight off the ISO, plus one 7.5 KiB extra initrd that fetches the install
payload from a URL given on the kernel cmdline.

*Opbevaring* (Danish, "storage" — see [Why "Opbevaring"?](#why-opbevaring))
is this repo/project: the hook, its build tooling and the iPXE examples.
A sibling of [Klargøring](https://github.com/knightmare2600/klargoring),
for the same estate and for the same reason — a vendor installer that only
knows how to start from physical media — but solved differently, see below.
Internal names in this repo (`opbevaring-fetch.service`,
`/scripts/live-bottom/opbevaring`, `opbevaring-hook.cpio`, the
`bootstrap/web/opbevaring/` folder) are named after this project.

Confirmed working end-to-end on real hardware, **both legacy BIOS and UEFI**
(2026-10-21, TrueNAS 25.10.2.1, opbevaring 1.0.1): PXE boot → payload fetch
→ stock TrueNAS installer → `truenas_admin` password prompt → install →
reboot into the installed system.

## Contents

- [Why "Opbevaring"?](#why-opbevaring)
- [Why this exists](#why-this-exists)
- [How it works](#how-it-works)
- [Why there are two initrds](#why-there-are-two-initrds)
- [Repository layout](#repository-layout)
- [Building](#building)
- [Serving](#serving)
- [Booting via iPXE](#booting-via-ipxe)
- [Kernel cmdline](#kernel-cmdline)
- [RAM](#ram)
- [Debugging a booted instance](#debugging-a-booted-instance)
- [Moving to a new TrueNAS release](#moving-to-a-new-truenas-release)
- [Status](#status)
- [Planned](#planned)
- [Release history](#release-history)

## Why "Opbevaring"?

"Opbevaring" is Danish for:

> storage / safekeeping

as in *bagageopbevaring*, a left-luggage office — somewhere things are put
to be kept safe. Fitting for a project whose whole job is installing a
storage system.

## Why this exists

TrueNAS has no supported PXE install path. The ISO is a Debian `live-boot`
system whose installer (`truenas_installer`, from
[truenas/truenas-installer](https://github.com/truenas/truenas-installer))
loop-mounts the install payload from a hardcoded path —
`/cdrom/TrueNAS-SCALE.update` in 25.10.2.1 — and the only thing that ever
puts it there is `/usr/sbin/mount-cd`, which probes local block devices for
the installation medium. PXE-boot the live system and there's no medium, so
there's nothing at `/cdrom` and the install fails.

The community workaround is to drop to a shell in the installer, download
the `.update` by hand and symlink it into place. This project automates
exactly that and nothing more: from the point the payload is in `/cdrom`
onward, it's the stock TrueNAS installer, unchanged.

### Why not do it the Klargøring way

Klargøring debootstraps Debian and `apt install`s Proxmox VE on top, because
Proxmox *is* a set of packages on Debian, and Proxmox's own installer can't
be separated from its ISO. TrueNAS is the other way round on both counts:

- The installed system isn't a set of packages, it's a sealed squashfs
  (`rootfs.squashfs` inside the `.update`) unpacked into
  `boot-pool/ROOT/<version>` by `truenas_install`, which runs from inside
  the `.update` itself.
- The installer itself is perfectly happy to run over the network — it's
  only the payload's *location* that's tied to physical media.

Partitioning, boot-pool creation, GRUB (BIOS and EFI) and the config
database are all owned by iXsystems' own installer code, so this project
reuses that code as-is rather than reimplementing any of it — which also
means it stays correct when iXsystems change those details between
releases.

## How it works

1. iPXE boots TrueNAS's own `vmlinuz` + `initrd.img` with `boot=live
   fetch=<url>/filesystem.squashfs` — `live-boot`'s standard netboot
   mechanism, which downloads the live root into RAM and boots it. The
   stock initrd already has `live-boot`'s networking, `udhcpc`, `wget` and
   a full set of NIC drivers.
2. iPXE also loads a second initrd, `opbevaring-hook.cpio` (see
   [Why there are two initrds](#why-there-are-two-initrds)). It adds
   `/scripts/live-bottom/{ORDER,opbevaring}` and `/opbevaring/*` to the
   initramfs.
3. `live-boot` runs whatever `/scripts/live-bottom/ORDER` lists (supported
   since live-boot 1:20180328, Debian #884355) after it has mounted the live
   root at `${rootmnt}`, and before `switch_root`. The hook — only if
   `update_url=` is on the cmdline — copies into the live root:
   - `opbevaring-fetch.service` + `/usr/local/sbin/opbevaring-fetch`, enabled
   - a mask for `mount-cd.service` (it would otherwise mount every local
     partition read-write looking for an installation medium)
   - `After=opbevaring-fetch.service` drop-ins for `getty@`, `serial-getty@`
     and `truenas-installer.service`, so neither the console TUI nor the
     JSON-RPC server starts before the payload is in place
   - a `systemd-networkd-wait-online --any` drop-in, so a multi-NIC box with
     one cable plugged in isn't held up by its other links
4. In the booted live system, `opbevaring-fetch` mounts a tmpfs on `/cdrom`,
   downloads `update_url=` into it (curl progress bar on the console),
   optionally checks `update_sha256=`, checks it's a squashfs, and puts it
   at the path `install.py` mounts. That path is read from `install.py`
   itself at runtime, not hardcoded, since the name differs between
   releases (`TrueNAS-SCALE.update` in 25.10.2.1, `TrueNAS.update` on
   truenas-installer's master branch).
5. The console autologin starts the stock TrueNAS installer TUI, which
   finds its payload where it expects it, and everything from there —
   disk selection, `truenas_admin` password, install, reboot — is the
   vendor's own.

## Why there are two initrds

```
initrd ${boot-url}/opbevaring/25.10.2.1/initrd.img            <- TrueNAS's, byte-for-byte off the ISO
initrd ${boot-url}/opbevaring/25.10.2.1/opbevaring-hook.cpio  <- ours, 7.5 KiB
```

The Linux kernel's initramfs format is defined as "a collection of
compressed and/or uncompressed cpio archives", built so that "archives
which are generated independently" can simply be concatenated
([kernel docs: initramfs buffer format](https://docs.kernel.org/driver-api/early-userspace/buffer-format.html)).
The kernel unpacks them in order into the same in-memory filesystem; a
later archive can add files alongside an earlier one's. When iPXE is given
several `initrd` lines, it hands them to the kernel back-to-back as exactly
that kind of concatenation — under both BIOS and UEFI (both confirmed in
this project's real-hardware test). It's the same concatenated layout
distributions already use to put CPU microcode in a separate, uncompressed
cpio in front of the main initrd
([kernel docs: microcode](https://docs.kernel.org/arch/x86/microcode.html)).

So the second `initrd` line isn't a second boot stage, a chain-load or a
replacement — the kernel ends up with one initramfs, which is TrueNAS's own
plus four extra small files of ours. Keeping them as two separate files
rather than merging ours into TrueNAS's is deliberate:

- **TrueNAS's files stay byte-identical to the ISO.** Every one of the four
  TrueNAS files on the web server can be checked against the ISO's own
  content (`SHA256SUMS`). Nothing of iXsystems' is repacked, so there's no
  question of whether a problem is ours or theirs.
- **No root, no unpack/repack.** Merging would mean `unmkinitramfs`,
  editing, and rebuilding TrueNAS's initrd with the right compression —
  per release. Appending needs none of that.
- **The hook is independent of the TrueNAS release.** Moving to a new
  TrueNAS version means replacing the four vendor files; the same
  `opbevaring-hook.cpio` goes alongside them unchanged (subject to the
  checks in [Moving to a new TrueNAS release](#moving-to-a-new-truenas-release)).
- **Nothing is overwritten.** TrueNAS's initrd has no `/scripts/live-bottom`
  at all (checked in 25.10.2.1), so our archive only ever adds files. The
  `init-bottom` hook stage was deliberately not used: its `ORDER` file
  already exists (it's udev's, which moves `/dev` into the new root), and
  replacing it would break the boot.
- **Uncompressed on purpose.** The TrueNAS kernel supports every initramfs
  compression (`CONFIG_RD_GZIP/XZ/ZSTD/...=y`), but gzip would save about
  4.5 KiB on a boot that downloads 2 GiB, and uncompressed can be inspected
  directly with `cpio -itv < opbevaring-hook.cpio`.

`cat initrd.img opbevaring-hook.cpio > combined.img` and a single `initrd`
line would give the kernel the same bytes; that's not been tested, and
there's no reason to prefer it over two lines.

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
`extract-iso.sh` reads the version from the live root's own `/etc/version`,
not the ISO's filename, and writes:

```
out/25.10.2.1/
  vmlinuz
  initrd.img
  filesystem.squashfs
  TrueNAS-SCALE.update
  SHA256SUMS
```

`build-hook-cpio.sh` then adds `opbevaring-hook.cpio` to the same folder.
The hook can also be taken prebuilt from the
[GitHub Releases](https://github.com/knightmare2600/opbevaring/releases);
TrueNAS's own files aren't published there, as they're iXsystems' to
distribute — extract them from the official ISO.

## Serving

Copy the version folder to the web root, one folder per TrueNAS version:

```
bootstrap/web/
  opbevaring/
    25.10.2.1/
      filesystem.squashfs
      initrd.img
      opbevaring-hook.cpio
      SHA256SUMS
      TrueNAS-SCALE.update
      vmlinuz
```

i.e. `${boot-url}/opbevaring/<version>/`. Any plain HTTP server works —
`live-boot`'s `fetch=` uses `wget`, the payload fetch uses `curl`, nothing
needs directory listings or range requests.

## Booting via iPXE

From `examples/menu.ipxe`:

```
:opbevaring
kernel ${boot-url}/opbevaring/25.10.2.1/vmlinuz boot=live fetch=${boot-url}/opbevaring/25.10.2.1/filesystem.squashfs update_url=${boot-url}/opbevaring/25.10.2.1/TrueNAS-SCALE.update nomodeset console=tty0
initrd ${boot-url}/opbevaring/25.10.2.1/initrd.img
initrd ${boot-url}/opbevaring/25.10.2.1/opbevaring-hook.cpio
boot
```

`:opbevaring-s` is the same with `console=ttyS0,115200n8` added. The two
`initrd` lines must stay in that order — TrueNAS's first, ours second.

## Kernel cmdline

- `boot=live fetch=<url>/filesystem.squashfs` — **required**, stock
  `live-boot` parameters. Don't add the ISO GRUB menu's
  `toram=filesystem.squashfs`: `fetch=` already downloads into RAM.
- `update_url=<url>` — **required**. Where to fetch the `.update` payload.
  Without it the hook does nothing at all, so the extra initrd is inert on
  any other boot.
- `update_sha256=<hex>` — optional. Verified before the file is handed over;
  the value for each release is in the `SHA256SUMS` that `extract-iso.sh`
  writes.
- `nomodeset`, `console=tty0` / `console=ttyS0,115200n8` — as in the ISO's
  own GRUB menu.

## RAM

Everything lives in RAM: the live squashfs (~230 MiB for 25.10.2.1) and the
`.update` (~1.8 GiB) plus the live system's own overlay. TrueNAS's own
documented minimum of 8 GB ("at least 8 GB of RAM for basic TrueNAS
operations", [hardware guide](https://www.truenas.com/docs/scale/gettingstarted/tnhardwareguide/))
covers that comfortably; the tmpfs on `/cdrom` is capped at 4 GiB.

## Debugging a booted instance

- `journalctl -u opbevaring-fetch --no-pager` — the fetch's own log. The
  console comes up even if the fetch fails (ordering only, no `Requires=`),
  so this is readable from the installer menu's "Shell" option.
- `ls -la /cdrom` — the payload, if it arrived.
- `ls -la /etc/systemd/system/mount-cd.service` — a symlink to `/dev/null`
  confirms the hook ran.
- A panic of "Unable to find a live file system on the network" is
  `live-boot`'s `fetch=` failing, before the hook is ever involved — check
  the `filesystem.squashfs` URL.

## Moving to a new TrueNAS release

1. `bash build/extract-iso.sh TrueNAS-SCALE-<new>.iso out`
2. Copy `opbevaring-hook.cpio` in alongside (or rebuild it).
3. Serve `out/<new>/` as `bootstrap/web/opbevaring/<new>/` and add a
   matching menu entry; leave the old version's folder and entry in place
   until the new one is proven.

The hook depends on three things in the TrueNAS image, all true for
25.10.2.1 and worth re-checking for a new release before relying on it:

- the initrd has no `/scripts/live-bottom/ORDER` of its own
  (`lsinitramfs initrd.img | grep scripts/live-bottom` prints nothing)
- `install.py` still mounts a literal `/cdrom/<something>.update` path
  (`unsquashfs -cat filesystem.squashfs usr/lib/python3/dist-packages/truenas_installer/install.py | grep cdrom`)
- `live-boot` is still the live system's boot mechanism (`boot=live` in the
  ISO's `/boot/grub/grub.cfg`)

## Status

Confirmed on real hardware (2026-10-21, 25.10.2.1): full install via the
stock TUI, under both legacy BIOS and UEFI, and on the serial console via
`:opbevaring-s` (on a Dell NAS).

Also checked against the 25.10.2.1 ISO, before that:

- the stock initrd's contents (no `/scripts/live-bottom`, `init-bottom/ORDER`
  is udev's, `live-boot` networking + `wget` present)
- the live root's `install.py` mounts `/cdrom/TrueNAS-SCALE.update` and is
  identical to truenas-installer master apart from that filename
- `mount-cd` in the live root is identical to scale-build master's
- the hook, run under the initrd's own busybox `sh`, writes exactly the
  intended files, writes nothing without `update_url=`, and refuses to run
  without `rootmnt`
- `opbevaring-fetch` against a local HTTP server: good download + sha256 OK;
  well-formed wrong sha256, malformed sha256, HTTP 404 and a non-squashfs
  file all rejected with the partial file removed; no `update_url=` is a
  clean no-op

Not yet exercised on hardware: `update_sha256=` (tested offline only, see
above), and any TrueNAS release other than 25.10.2.1.

## Planned

- Unattended install: an answer TOML (`toml_url=`, the estate's
  `${site-prefix}-answer.toml` convention) driving
  `truenas_installer.install.install()` directly — disks, `truenas_admin`
  password, `post_install.network_interfaces` for the static `.19` — with
  Klargøring's `confirm-wipe` / `unattended` / `no-reboot` safety flags.

## Release history

- **1.0.1** (2026-10-21) — first release. Web layout
  `bootstrap/web/opbevaring/<version>/`. Confirmed end-to-end on BIOS and
  UEFI with TrueNAS 25.10.2.1. `opbevaring-hook.cpio` is byte-identical to
  the pre-release build that test used.
- `opbevaring-20261021-25.10.2.1-1` (2026-10-21) — pre-release test build,
  same hook; examples used a `truenas/opbevaring/` web path.
