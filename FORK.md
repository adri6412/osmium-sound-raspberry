# FORK.md — Osmium Sound for Raspberry Pi (Pi 4, Pi 5, Compute Module 4/5)

This repository is a fork of the main Osmium Sound appliance
(`adri6412/hifi-media-player`), ported to run on the **Raspberry Pi 4, Pi 5 and
Compute Module 4/5 from a single image**, with **full feature parity with the
x86 build** (bundled Lyrion, DSP / PCM→DSD, CD ripping, the web admin,
Bluetooth, systemd-sysext add-ons, the Qt kiosk on eglfs/KMS).

The image is running on real hardware: the reference device is a **Compute
Module 5 Lite** (BCM2712, kernel `6.18.60+rpt-rpi-2712`, Debian trixie).

## Provenance

- **Fork point**: branch `alpha`, commit **`9631fd8`** = tag
  **`v2.5.26-dev.6-alpha3`** (the latest x86 alpha at the time of the fork,
  2026-11-14), seeded with `git archive` so only tracked files came across (the
  fork keeps no shared history with the x86 repo).
- **App baseline now**: the app layer was re-synced to x86
  **`v2.5.26-dev.8-alpha6`** (commit `a72d01b`), keeping only the Pi platform
  layer on top (boot, OTA, CI, CamillaDSP arch). Pi tags carry **no** leading
  `v` — the current release is **`2.5.26-dev.6-alpha15`**.
- This is **not** the Pi3 player-only fork (`osmium-sound-pi3-playeronly`), which
  strips Lyrion/DSP and boots through U-Boot. We reuse only its arm64 *build
  recipe* (debootstrap → squashfs → RAUC, Qt payload cross-build), never its
  stripping. Everything the x86 image does, this image does.

> 🚨 **Code parity.** Every change to the custom Osmium app code
> (api/qt/webui/np/recommend) must be made on **both** builds (`osmium-sound`
> and `osmium-sound-raspberry`); only the platform layer (boot/OTA/CI/CamillaDSP
> arch) is allowed to diverge. The I2S HAT selector and the OTA-prune workflow
> below are the explicitly-approved Pi-only exceptions.

## What changed from x86 (and why)

| Area | x86 | Raspberry Pi |
|------|-----|--------------|
| Boot / A-B | GRUB + grubenv on an ESP | **Pi firmware tryboot**: `autoboot.txt` + `[boot_partition=N]`, GPT, no GRUB/U-Boot; `[cm4]`/`[cm5]` config.txt sections for the Compute Modules |
| Kernel | Debian `linux-image-amd64` (pinned) | downstream Raspberry `linux-image-rpi-v8` (Pi4, BCM2711) + `linux-image-rpi-2712` (Pi5/CM, BCM2712, `…+rpt-rpi-2712`), `raspi-firmware`, `rpi-eeprom`, apt-pinned |
| RAUC backend | GRUB | `bootloader=custom` → `hifi-rpi-boot.sh` (arms tryboot / commits on mark-good) |
| Disk image | `build-usb-image.sh` (ESP + slots) | `build-image-rpi.sh`: GPT 6 partitions — selector FAT (`hifi-rpifw`), 2 boot FATs (`hifi-boot-a/-b`, `LegacyBIOSBootable`), 2 raw root slots, data seed (`hifi-data-grow`, grown+formatted on first boot) |
| OTA | `osmium-sound.pages.dev` + `file.osmiumsound.it/ota` + `hifi-image-*.raucb` | GitHub Release (tag + assets) + **Oracle Object Storage (Milan)** `ota-rpi/` as the sole manifest source + mirror, with a GitHub REST API fallback + `osmium-rpi-*.raucb` |
| Audio | ALSA sinks as-is | HDMI sinks rendered through `plughw` at a fixed ELD-capped rate; **I2S DAC/HAT board picker in Settings** (Pi-only, writes `dtoverlay` to config.txt) |
| Display | KMS card0 | Qt eglfs auto-detects the DRM card that actually has a connector (not hardcoded card0), so the kiosk renders on Pi 5/CM too |
| DSP binary | CamillaDSP `amd64` | CamillaDSP `aarch64` |

The firmware auto-selects `kernel8.img` on a Pi4 (BCM2711) and `kernel_2712.img`
on a Pi5/CM (BCM2712), plus the matching DTB, so the one image boots every board.

## Pi-only features and fixes added since the fork

- **Compute Module 4/5 boot** — `[cm4]`/`[cm5]` config.txt sections (`2e03825`);
  the selector FAT sized as a real FAT32 (`1541d02`) and the boot FATs flagged
  GPT `LegacyBIOSBootable` (`207dbee`) so the CM5 bootloader finds them; CMA
  sized via `config.txt` (`cma-256`) instead of a `cma=` cmdline arg, which put
  the CMA above 1 GB and hung the kernel on Pi 5/CM5 (`ba8d35b`).
- **I2S DAC/HAT board selector** in Settings (`81d50fb`, apply-on-pick `78c0835`)
  — ~68 boards from moOde's table; writes a managed `dtoverlay` block into
  config.txt on both boot FATs and re-injects it on every OTA via
  `/etc/hifi-player/dac-hat.conf`. Pi-only (hidden off-Pi). Separate from the
  runtime ALSA output picker — a HAT is not an ALSA card until its overlay loads
  at boot.
- **HDMI audio** rendered through `plughw` at a fixed ELD-capped rate (`10f6dac`)
  — on the CM5 only one HDMI port carries DMA audio.
- **Qt kiosk payload staged in RAM** (tmpfs) to smooth screen changes off the
  read-only squashfs (`c82ef4a`).
- **Store signature** verified with the upstream x86 key, not the fork OTA key
  (`1449de8`).
- **CI**: the image builds + publishes on a pushed `*-alpha*` tag (`dfc0d11`,
  sign+publish automatic like x86); Oracle Object Storage is the sole OTA
  manifest source (`dfc9263`); a `prune-ota-oracle` workflow keeps only the
  current release per channel (`3f169df`, needs the OCI Customer Secret Key
  secrets to actually delete).

## Key new / adapted files

- `distro/build-rpi.sh` — arm64 rootfs + Pi archive + RAUC bundle (`compatible=osmium-rpi`).
- `distro/build-image-rpi.sh` — GPT tryboot disk image (6 partitions).
- `distro/config/package-lists/hifi-rpi.list.chroot` — x86 list − x86-only + arm/Pi.
- `distro/rpi-boot/` — `autoboot.txt`, `config.txt` (with the `# >>> osmium-dac` managed block), `cmdline.txt.tmpl`, `dac-cards.json`.
- `distro/config/includes.chroot/usr/local/sbin/hifi-rpi-boot.sh` — RAUC custom backend.
- `distro/config/includes.chroot/usr/local/sbin/hifi-rpi-bootfat.sh` — boot-FAT assembler (shared by build + OTA hook; re-injects the DAC overlay choice).
- `distro/config/includes.chroot/usr/local/sbin/hifi-rpi-dacoverlay.sh` — idempotent config.txt DAC-overlay renderer.
- `distro/config/includes.chroot/usr/local/sbin/hifi-rpi-reboot.sh` — tryboot reboot wrapper.
- `distro/config/includes.chroot/usr/local/share/hifi-ab/system.conf.rpi` — RAUC `bootloader=custom`.
- `distro/rauc/hook.sh` — `slot-post-install` assembles the new slot's boot FAT.
- `.github/workflows/build-rpi-image.yml` — arm64 CI (payload + image + Release + Oracle Object Storage mirror; tag-triggered).
- `.github/workflows/prune-ota-oracle.yml` — trims the Oracle OTA mirror to the current release per channel.

## Verified on real hardware (Compute Module 5 Lite)

The following, which used to be untested, are now **confirmed working** on the
reference CM5 Lite:

- Downstream package names and the `-rpi-v8` / `-rpi-2712` kernel flavours
  (device runs `6.18.60+rpt-rpi-2712`).
- The RAUC custom backend and tryboot (`reboot "0 tryboot"`): OTA updates install
  and boot into the new slot.
- EEPROM new enough for GPT `[boot_partition]` boot (plus the
  `LegacyBIOSBootable` FAT attribute the CM5 bootloader needs).
- `/data` is ext4 on `hifi-data` (grown + provisioned on first boot); `/etc` is a
  real overlay on `/data`, so settings persist across OTA.

Still worth watching rather than assumed safe:

- The Oracle Object Storage READ/WRITE PARs have a mandatory expiry; on lapse the
  device falls back to the GitHub REST API and the CI mirror step is skipped with
  a warning. The prune workflow instead needs the OCI **Customer Secret Key**
  secrets (the WRITE PAR can't list/delete) and skips cleanly if they're absent.
- Pi 4 (BCM2711) itself has not been exercised as thoroughly as the CM5; the
  shared image is built for it but the hands-on testing has been on the CM5.
