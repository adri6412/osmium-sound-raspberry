# FORK.md — Osmium Sound for Raspberry Pi 4 & Pi 5

This repository is a fork of the main Osmium Sound appliance
(`adri6412/hifi-media-player`), ported to run on the **Raspberry Pi 4 and
Raspberry Pi 5 from a single image**, with **full feature parity with the x86
build** (bundled Lyrion, DSP / PCM→DSD, CD ripping, the web admin, Bluetooth,
systemd-sysext add-ons, the Qt kiosk on eglfs/KMS).

## Provenance

- **Base**: branch `alpha`, commit **`9631fd8`** = tag **`v2.5.26-dev.6-alpha3`**
  (the latest alpha at the time of the fork, 2026-11-14), seeded with
  `git archive` so only tracked files came across.
- This is **not** the Pi3 player-only fork (`osmium-sound-pi3-playeronly`), which
  strips Lyrion/DSP and boots through U-Boot. We reuse only its arm64 *build
  recipe* (debootstrap → squashfs → RAUC, Qt payload cross-build), never its
  stripping. Everything the x86 image does, this image does.

## What changed from x86 (and why)

| Area | x86 | Raspberry Pi 4 & 5 |
|------|-----|--------------------|
| Boot / A-B | GRUB + grubenv on an ESP | **Pi firmware tryboot**: `autoboot.txt` + `[boot_partition=N]`, GPT, no GRUB/U-Boot |
| Kernel | Debian `linux-image-amd64` (pinned) | downstream Raspberry `linux-image-rpi-v8` (Pi4) + `linux-image-rpi-2712` (Pi5), `raspi-firmware`, `rpi-eeprom`, apt-pinned |
| RAUC backend | GRUB | `bootloader=custom` → `hifi-rpi-boot.sh` (arms tryboot / commits on mark-good) |
| Disk image | `build-usb-image.sh` (ESP + slots) | `build-image-rpi.sh`: GPT 6 partitions (selector FAT, 2 boot FATs, 2 raw root slots, data) |
| OTA | `osmium-sound.pages.dev` + `file.osmiumsound.it/ota` + `hifi-image-*.raucb` | GitHub Release (tag + assets) + Oracle Object Storage (Milan) `ota-rpi/` manifest & mirror + GitHub REST API fallback + `osmium-rpi-*.raucb` |
| DSP binary | CamillaDSP `amd64` | CamillaDSP `aarch64` |

The firmware auto-selects `kernel8.img` on a Pi4 (BCM2711) and `kernel_2712.img`
on a Pi5 (BCM2712), plus the matching DTB, so the one image boots both boards.

## Key new / adapted files

- `distro/build-rpi.sh` — arm64 rootfs + Pi archive + RAUC bundle (`compatible=osmium-rpi`).
- `distro/build-image-rpi.sh` — GPT tryboot disk image (6 partitions).
- `distro/config/package-lists/hifi-rpi.list.chroot` — x86 list − x86-only + arm/Pi.
- `distro/rpi-boot/` — `autoboot.txt`, `config.txt`, `cmdline.txt.tmpl`.
- `distro/config/includes.chroot/usr/local/sbin/hifi-rpi-boot.sh` — RAUC custom backend.
- `distro/config/includes.chroot/usr/local/sbin/hifi-rpi-bootfat.sh` — boot-FAT assembler (shared by build + OTA hook).
- `distro/config/includes.chroot/usr/local/sbin/hifi-rpi-reboot.sh` — tryboot reboot wrapper.
- `distro/config/includes.chroot/usr/local/share/hifi-ab/system.conf.rpi` — RAUC `bootloader=custom`.
- `distro/rauc/hook.sh` — `slot-post-install` assembles the new slot's boot FAT.
- `.github/workflows/build-rpi-image.yml` — arm64 CI (payload + image + Release + Oracle Object Storage mirror).

## 🚨 Still to verify on real hardware (cannot be tested without a Pi4/Pi5)

- Exact downstream package names in `archive.raspberrypi.com/debian trixie` and the
  kernel flavour suffixes `-rpi-v8` / `-rpi-2712` (the build asserts on them).
- The RAUC `bootloader-custom-backend=` option name against the installed RAUC
  version, and that `reboot "0 tryboot"` arms tryboot with the chosen kernel
  (vcmailbox `0x00038064` fallback needs `/dev/vcio`).
- EEPROM recent enough for GPT `[boot_partition]` (rpi-eeprom ≥ 2025-03-10).
- The Oracle Object Storage READ/WRITE PARs do not expire silently mid-release
  (they have a mandatory expiry; on lapse the device falls back to the GitHub
  REST API and the CI mirror step is skipped with a warning).
