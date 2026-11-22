#!/usr/bin/env bash
#
# build-rpi.sh — build the Osmium Sound (Raspberry Pi 4 + Pi 5, arm64,
# FULL-FEATURE) system image: an arm64 Debian trixie rootfs with the complete
# appliance payload (same features as the x86 build: bundled-at-first-boot
# Lyrion, DSP/PCM→DSD, CD ripping, web admin, Bluetooth, Samba …), turned into
# the read-only rootfs.squashfs that goes into a RAUC A/B slot, plus the signed
# RAUC bundle (.raucb) used to update a running device.
#
# This is the arm64 counterpart of build-distro.sh + build-image.sh combined,
# reusing the arm64 build mechanics from the Pi3 player-only fork but WITHOUT
# the stripping: everything the x86 appliance has is kept.
#
# Unlike the x86 flow it does NOT use live-build (no live ISO) and it has NO
# GRUB. A SINGLE image boots BOTH the Pi 4 and the Pi 5: the VideoCore firmware
# auto-selects the right kernel (kernel8 for 2711/Pi4, kernel_2712 for Pi5) and
# the right DTB by board. A/B updates use the firmware's **tryboot** mechanism
# (autoboot.txt + [boot_partition=N] + vcmailbox), NOT U-Boot — U-Boot has no
# PCIe/USB on the Pi 5. The disk .img is assembled separately by
# build-image-rpi.sh from the rootfs.squashfs this script produces.
#
#   sudo ./build-rpi.sh --version 2.6.0-rpi.1 \
#        --cert ../rauc-keys/cert.pem --key ../rauc-keys/key.pem
#
# Run it on an arm64 Debian host (native, no emulation) or on an x86 host with
# qemu-user-static + binfmt registered for aarch64 (slower). The CI workflow
# (.github/workflows/build-rpi-image.yml) runs it on a native arm64 runner.
#
# 🚨 Kernel & firmware come from the Raspberry Pi archive (archive.raspberrypi.com),
# NOT from Debian: the downstream kernel is what gives full Pi 5 (RP1/BCM2712)
# support and the /dev/vcio needed by `vcmailbox` for tryboot. The Debian
# userland is kept; only kernel/firmware/EEPROM are pinned to the Pi archive.
#
# Needs root. Host tools: debootstrap, mksquashfs, rauc, curl, gpg. The Qt
# payload (/opt/hifi-qt/hifi-qt) must already be present under
# config/includes.chroot, cross-built for arm64 by native-ui-qt/ci/build-payload.sh —
# this script refuses to build an image without it, just as hook 0300 does,
# because an image with no interface is a black screen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$SCRIPT_DIR/config"
# Shared custom app code lives in the osmium-core submodule (core/), not at the
# repo root any more. Every read of app code resolves against $CORE.
CORE="$REPO_ROOT/core"
VERSION="${IMAGE_VERSION:-}"
OUT="${IMAGE_OUT:-$REPO_ROOT}"
SUITE="${DEBIAN_SUITE:-trixie}"
MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
RASPI_MIRROR="${RASPI_MIRROR:-http://archive.raspberrypi.com/debian}"
RASPI_KEY_URL="${RASPI_KEY_URL:-https://archive.raspberrypi.org/debian/raspberrypi.gpg.key}"
ARCH=arm64
CERT="${RAUC_CERT:-}"
KEY="${RAUC_KEY:-}"
KEYRING="${RAUC_KEYRING:-$SCRIPT_DIR/rauc-keys/keyring.pem}"
NO_BUNDLE=0
KEEP_ROOTFS=0
CHROOT_KEEP=""
# A/B slot size. Same 1280 MiB as the x86 build: the full-feature squashfs is
# ~900 MiB (two Pi kernels + initrds add ~60 MiB over x86) with a third of margin
# under the 90% build cap. MUST match AB_SLOT_B_MIB in hifi-ab-lib.sh (checked
# below): the pre-check, the initrd grow and the installer all read it.
SLOT_MIB="${AB_SLOT_B_MIB:-1280}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" log -1 --format=%ct 2>/dev/null || date +%s)}"

log() { printf '\033[1;36m[hifi-rpi]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[hifi-rpi ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --suite) SUITE="$2"; shift 2 ;;
        --mirror) MIRROR="$2"; shift 2 ;;
        --cert) CERT="$2"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --keyring) KEYRING="$2"; shift 2 ;;
        --no-bundle) NO_BUNDLE=1; KEEP_ROOTFS=1; shift ;;
        --keep-rootfs) KEEP_ROOTFS=1; shift ;;
        --keep-chroot) CHROOT_KEEP="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "needs root"
[ -n "$VERSION" ] || die "--version missing"
[ "$SUITE" = trixie ] || log "WARNING: suite=$SUITE (trixie is the tested base: Qt6 needs Debian 13)"
command -v debootstrap >/dev/null || die "debootstrap missing on the build host"
command -v mksquashfs  >/dev/null || die "mksquashfs (squashfs-tools) missing on the build host"
[ "$NO_BUNDLE" = 1 ] || command -v rauc >/dev/null || die "rauc missing on the build host (or pass --no-bundle)"
[ -f "$KEYRING" ] || die "RAUC keyring missing: $KEYRING"
[ -x "$CONFIG/includes.chroot/opt/hifi-qt/hifi-qt" ] \
    || die "config/includes.chroot/opt/hifi-qt/hifi-qt missing or not executable: cross-build the arm64 payload with native-ui-qt/ci/build-payload.sh first"
# A quick sanity check that the payload really is arm64 and not an x86 build
# left over from a desktop test: an aarch64 ELF has 0xB7 at byte 18 (e_machine).
if command -v od >/dev/null; then
    _mach=$(od -An -tu1 -j18 -N1 "$CONFIG/includes.chroot/opt/hifi-qt/hifi-qt" | tr -d ' ')
    [ "$_mach" = 183 ] || die "config/includes.chroot/opt/hifi-qt/hifi-qt is not an aarch64 ELF (e_machine=$_mach, want 183): wrong-arch payload"
fi
mkdir -p "$OUT"

PKGLIST="$CONFIG/package-lists/hifi-rpi.list.chroot"
[ -f "$PKGLIST" ] || die "missing $PKGLIST"
SHARE_SRC="$CONFIG/includes.chroot/usr/local/sbin/hifi-ab-lib.sh"
lib_slot=$(sed -n 's/^AB_SLOT_B_MIB="\${AB_SLOT_B_MIB:-\([0-9]*\)}"/\1/p' "$SHARE_SRC" 2>/dev/null | head -n 1)
[ -z "$lib_slot" ] || [ "$lib_slot" = "$SLOT_MIB" ] \
    || die "slot size mismatch: build-rpi=$SLOT_MIB, hifi-ab-lib.sh=$lib_slot"

WORK="$(mktemp -d "${IMAGE_WORK:-/var/tmp}/hifi-rpi.XXXXXX")"
CH="$WORK/chroot"
SHARE="$CONFIG/includes.chroot/usr/local/share/hifi-ab"
cleanup() {
    set +e
    for m in "$CH/run" "$CH/dev/pts" "$CH/dev" "$CH/sys" "$CH/proc"; do
        mountpoint -q "$m" && umount -R "$m" 2>/dev/null
    done
    [ -n "$CHROOT_KEEP" ] && [ -d "$CH" ] && { rm -rf "$CHROOT_KEEP"; cp -a "$CH" "$CHROOT_KEEP"; }
    rm -rf "$WORK"
}
trap cleanup EXIT

in_chroot() {
    chroot "$CH" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C.UTF-8 LANG=C.UTF-8 HOME=/root DEBIAN_FRONTEND=noninteractive "$@"
}

# ── 1. base system (debootstrap, arm64) ──────────────────────────────────
log "debootstrap $SUITE/$ARCH into the build chroot"
# --foreign is only needed when there is no aarch64 binfmt handler; on a native
# arm64 host (the CI runner) a plain debootstrap works and is much faster.
if [ "$(uname -m)" = "aarch64" ]; then
    debootstrap --arch="$ARCH" --variant=minbase \
        --components=main,contrib,non-free,non-free-firmware \
        "$SUITE" "$CH" "$MIRROR" 2>&1 | tail -n 5 || die "debootstrap failed"
else
    command -v qemu-aarch64-static >/dev/null \
        || die "cross build needs qemu-aarch64-static + binfmt (install qemu-user-static)"
    debootstrap --arch="$ARCH" --variant=minbase --foreign \
        --components=main,contrib,non-free,non-free-firmware \
        "$SUITE" "$CH" "$MIRROR" 2>&1 | tail -n 5 || die "debootstrap (stage 1) failed"
    cp "$(command -v qemu-aarch64-static)" "$CH/usr/bin/"
    in_chroot /debootstrap/debootstrap --second-stage 2>&1 | tail -n 5 || die "debootstrap (stage 2) failed"
fi

# Debian apt sources (same areas live-build gives the x86 image).
cat > "$CH/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
deb $MIRROR ${SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free non-free-firmware
EOF

mount -t proc proc "$CH/proc"
mount -t sysfs sys "$CH/sys"
mount --bind /dev "$CH/dev"
mount -t devpts devpts "$CH/dev/pts" 2>/dev/null || true
mount -t tmpfs tmpfs "$CH/run"
printf '#!/bin/sh\nexit 101\n' > "$CH/usr/sbin/policy-rc.d"; chmod +x "$CH/usr/sbin/policy-rc.d"
cp -a "$CH/etc/resolv.conf" "$WORK/resolv.conf.orig" 2>/dev/null || true
cp -L /etc/resolv.conf "$CH/etc/resolv.conf" 2>/dev/null || true

in_chroot apt-get -q update 2>&1 | tail -n 3 || die "apt update (Debian) failed"
in_chroot apt-get -y -q install eatmydata ca-certificates curl gnupg >/dev/null 2>&1 \
    || die "installing ca-certificates/curl/gnupg failed (needed to add the Pi archive)"

# ── 1b. the Raspberry Pi archive (downstream kernel + firmware + rpi-eeprom) ──
# 🚨 Pinned LOW by default (priority 100 < Debian 500) so ONLY the kernel,
# firmware and EEPROM come from here; the rest of the userland stays Debian. See
# apt/preferences.d below. The key is fetched and dearmored (the Debian build
# host has no raspberrypi-archive-keyring package).
log "adding the Raspberry Pi archive ($RASPI_MIRROR) for kernel + firmware"
in_chroot sh -c "curl -fsSL '$RASPI_KEY_URL' | gpg --dearmor -o /usr/share/keyrings/raspberrypi-archive-keyring.gpg" \
    || die "could not fetch the Raspberry Pi archive key ($RASPI_KEY_URL)"
printf 'deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] %s %s main\n' \
    "$RASPI_MIRROR" "$SUITE" > "$CH/etc/apt/sources.list.d/raspi.list"
# Only the Pi kernel/firmware/EEPROM win from the Pi archive; everything else
# must resolve from Debian so we do not fork the userland.
cat > "$CH/etc/apt/preferences.d/raspi.pref" <<'PREF'
Package: *
Pin: origin archive.raspberrypi.com
Pin-Priority: 100

Package: linux-image-rpi-v8 linux-image-rpi-2712 linux-headers-rpi-v8 linux-headers-rpi-2712 raspi-firmware rpi-eeprom rpi-eeprom-images raspi-utils-core
Pin: origin archive.raspberrypi.com
Pin-Priority: 990
PREF
# 🚨 Debian 13 (trixie) verifies repository signatures with sqv, whose crypto
# policy rejects SHA1 binding signatures since 2026-02-01. The Raspberry Pi
# archive key's self-signature is still SHA1, so apt would reject
# archive.raspberrypi.com as "not signed" (sqv exit 1). Re-allow SHA1 for this
# chroot's apt — the confirmed workaround from raspberrypi/rpi-image-gen#171 —
# until the Pi archive key is re-signed with a stronger hash. Written as a file
# so it also covers every later apt update/install, not just this one.
mkdir -p "$CH/etc/crypto-policies/back-ends"
printf '[hash_algorithms]\nsha1 = "always"\n' > "$CH/etc/crypto-policies/back-ends/sequoia.config"
in_chroot apt-get -q update 2>&1 | tail -n 3 || die "apt update (Debian + Pi archive) failed"

# ── 2. the appliance package set (arm64 list) + kernels + essentials ──────
log "installing the full appliance package set + Pi kernels/firmware"
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$PKGLIST")
# The two downstream kernels (v8 = Pi4/BCM2711, 2712 = Pi5/BCM2712) and the
# firmware are installed explicitly here, outside the list, so a list typo can
# never silently drop the kernel. raspi-firmware wires /boot/firmware.
in_chroot apt-get -y -q --no-install-recommends install \
    locales ca-certificates \
    linux-image-rpi-v8 linux-image-rpi-2712 raspi-firmware rpi-eeprom \
    "${PKGS[@]}" 2>&1 | tail -n 20 \
    || die "installing the package set failed"
in_chroot dpkg -s busybox >/dev/null 2>&1 \
    || die "busybox missing in the chroot: the initrd would have no grep/sed/cp"
in_chroot dpkg -s raspi-firmware >/dev/null 2>&1 \
    || die "raspi-firmware missing: the Pi GPU firmware would not be on the boot partition"
in_chroot dpkg -s linux-image-rpi-v8 >/dev/null 2>&1 \
    || die "linux-image-rpi-v8 missing: no Pi4 (BCM2711) kernel"
in_chroot dpkg -s linux-image-rpi-2712 >/dev/null 2>&1 \
    || die "linux-image-rpi-2712 missing: no Pi5 (BCM2712) kernel"

# ── 3. the appliance payload (config/includes.chroot overlaid onto /) ─────
log "overlaying config/includes.chroot"
tar -C "$CONFIG/includes.chroot" -cf - . | tar -C "$CH" -xf -

# Ship the Pi-boot templates (autoboot.txt / config.txt / cmdline.txt) into the
# rootfs so the RAUC slot-post-install hook can regenerate the FAT boot content
# on every OTA. These files live on the shared/boot FAT partitions and are NOT
# part of a slot, so without this a config.txt/cmdline change reaches a device
# only via a full .img reflash, never over the air. Single source of truth:
# distro/rpi-boot/ (the same files build-image-rpi.sh lays onto the FAT).
log "shipping rpi-boot templates → /usr/local/share/hifi-ab/rpi-boot (for boot-over-OTA)"
mkdir -p "$CH/usr/local/share/hifi-ab/rpi-boot"
cp -f "$SCRIPT_DIR"/rpi-boot/* "$CH/usr/local/share/hifi-ab/rpi-boot/"

# Python daemons from the repo root → /usr/local/bin (single source of truth),
# exactly as the x86 build-distro.sh injects them into includes.chroot.
log "injecting python daemons → /usr/local/bin"
BIN_DEST="$CH/usr/local/bin"
mkdir -p "$BIN_DEST"
# The four server entrypoints are explicit; EVERY hifi_*.py library module ships
# too. api_server.py imports some of them unguarded at import time
# (import hifi_system_tweaks as stw, …), so a single missing module crash-loops
# the service and the kiosk shows "API server unavailable". Copying the whole
# hifi_*.py set via glob — exactly what the x86 includes.chroot carries — keeps
# this robust against new modules instead of a hand-maintained list that drifts.
for py in api_server.py vu_meter_daemon.py sources_server.py webui_server.py; do
    [ -f "$CORE/$py" ] || { log "  (skip $py — not in core/)"; continue; }
    cp -f "$CORE/$py" "$BIN_DEST/$py"
    sed -i 's/\r$//' "$BIN_DEST/$py"
done
for py in "$CORE"/hifi_*.py; do
    [ -f "$py" ] || continue                       # no match → literal glob, skip
    cp -f "$py" "$BIN_DEST/"
    sed -i 's/\r$//' "$BIN_DEST/$(basename "$py")"
done
chmod 0755 "$BIN_DEST"/*.py 2>/dev/null || true

# ── 4. chroot hooks — a Pi-safe FULL-FEATURE allowlist ────────────────────
# Unlike the Pi3 player-only fork, the DSP (sox-ng) and CD reader hooks DO run:
# this image has the same features as x86. Deliberately skipped:
#   0200-hidden-boot        GRUB/x86 boot finalisation (no GRUB on the Pi)
#   0400-pin-kernel         pins the x86 Debian kernel (we use the Pi kernels)
#   0410-tailscale          optional VPN; left out of the base image
#   0420-broadcom-wl        builds the BCM4360 wl DKMS driver (an x86 PCIe card)
#   0440-surface-ipts       Microsoft Surface touch (x86 tablet)
#   0450-purge-raspi-firmware  removes raspi-firmware — 🚨 FATAL here, we need it
#   0500-brand-boot.*.binary  live-build ISO stage hook (no ISO here)
log "running the Pi-safe full-feature chroot hooks"
for h in 0100-system-setup 0300-app-install 0400-enable-services \
         0430-sox-ng 0435-osmium-cdread; do
    f="$CONFIG/hooks/normal/$h.hook.chroot"
    [ -f "$f" ] || die "expected hook missing: $f"
    log "  hook $h"
    cp "$f" "$CH/tmp/hook.sh"; chmod +x "$CH/tmp/hook.sh"
    in_chroot /tmp/hook.sh 2>&1 | tail -n 10 || die "hook $h failed"
    rm -f "$CH/tmp/hook.sh"
done

# ── 5. image post-processing (full-feature, from build-image.sh, no GRUB) ─
log "image post-processing: strip live markers, Lyrion, A/B units, sysext"
# Services that make no sense in a sealed appliance image.
in_chroot systemctl mask NetworkManager-wait-online.service systemd-binfmt.service \
    networking.service e2scrub_reap.service e2scrub_all.timer keyboard-setup.service \
    nmbd.service samba-ad-dc.service >/dev/null 2>&1 || true
rm -f "$CH/etc/kernel/postinst.d/zzz-hifi-fix-efi-boot" \
      "$CH/etc/apt/apt.conf.d/99-hifi-fix-efi-boot" \
      "$CH/etc/apt/apt.conf.d/52hifi-unattended"
# x86 drops hifi-firstboot.service because the image uses hifi-lyrion-ensure
# instead; keep that behaviour here.
rm -f "$CH/etc/systemd/system/hifi-firstboot.service" "$CH"/etc/systemd/system/*.wants/hifi-firstboot.service
rm -f "$CH/etc/hifi-player/OS_VERSION" "$CH/etc/hifi-player/SYSTEM_VERSION" \
      "$CH/etc/hifi-player/UI_VERSION" "$CH/etc/hifi-player/provisioning-pending"
rm -f "$CH/etc/rauc/system.conf"   # replaced below by the static Pi system.conf

# Lyrion: symlink to /data/lyrion/current, downloaded on boot by hifi-lyrion-ensure
# (the .deb is _all / arch-neutral, so this works identically to x86).
log "Lyrion: symlink to /data/lyrion/current + enable units"
mkdir -p "$CH/usr/share/perl5" "$CH/data"
lyrion_links=(
    "usr/share/squeezeboxserver" "usr/share/perl5/Slim"
    "usr/sbin/squeezeboxserver" "usr/sbin/squeezeboxserver_safe" "usr/sbin/squeezeboxserver-scanner"
    "usr/sbin/squeezeboxserver-resized" "usr/sbin/squeezeboxserver-cleanup"
    "etc/squeezeboxserver" "etc/default/lyrionmusicserver"
)
for rel in "${lyrion_links[@]}"; do
    rm -rf "${CH:?}/$rel"
    ln -sfn "/data/lyrion/current/$rel" "$CH/$rel"
done
for u in lyrionmusicserver hifi-lyrion-ensure hifi-lyrion-plugins-ensure \
         hifi-cdplayer-tolerate hifi-cdplayer-enable; do
    [ -f "$SHARE/$u.service" ] && install -m 0644 "$SHARE/$u.service" "$CH/usr/lib/systemd/system/$u.service"
done
in_chroot systemctl enable lyrionmusicserver.service hifi-lyrion-ensure.service \
    hifi-lyrion-plugins-ensure.service hifi-cdplayer-tolerate.service hifi-cdplayer-enable.service >/dev/null 2>&1
# A/B health: hifi-boot-health runs `rauc status mark-good` on a healthy boot,
# which on the Pi routes through the custom backend (hifi-rpi-boot.sh) to make
# the booted slot permanent in autoboot.txt. hifi-ab-firstboot grows /data on
# first boot. We do NOT enable hifi-rauc-config.service: that unit regenerates a
# GRUB/ESP system.conf per boot (x86); the Pi uses the static, by-partlabel
# system.conf installed below with bootloader=custom.
in_chroot systemctl enable hifi-boot-health.service \
    hifi-boot-watchdog.timer hifi-ab-firstboot.service >/dev/null 2>&1 || true
in_chroot systemctl disable hifi-rauc-config.service hifi-ab-finish.service >/dev/null 2>&1 || true

# Static RAUC system.conf for the Pi (bootloader=custom → hifi-rpi-boot.sh). The
# slots are addressed by GPT PARTLABEL via /dev/disk/by-partlabel, which udev
# creates from the labels build-image-rpi.sh writes, so no per-boot generation
# is needed (unlike the x86 ESP whose device path varies).
install -D -m 0644 "$SHARE/system.conf.rpi" "$CH/etc/rauc/system.conf" 2>/dev/null \
    || install -D -m 0644 "$SCRIPT_DIR/config/includes.chroot/usr/local/share/hifi-ab/system.conf.rpi" "$CH/etc/rauc/system.conf"

# Fixed-UID users and state directories.
in_chroot systemd-sysusers >/dev/null 2>&1 || die "systemd-sysusers failed"
in_chroot id squeezeboxserver >/dev/null || die "squeezeboxserver user not created"
for d in var/lib/squeezeboxserver var/lib/squeezeboxserver/prefs var/lib/squeezeboxserver/cache \
         var/lib/squeezeboxserver/playlists var/log/squeezeboxserver; do
    mkdir -p "$CH/$d"; in_chroot chown squeezeboxserver:nogroup "/$d"
done
in_chroot chown hifimusic:hifishare /var/lib/squeezeboxserver/playlists
in_chroot chmod 2775 /var/lib/squeezeboxserver/playlists
mkdir -p "$CH/var/lib/hifi-player" "$CH/var/log/hifi" "$CH/mnt" "$CH/media"

# RAUC keyring + version markers outside /etc; NBD for `rauc install https://…`.
mkdir -p "$CH/etc/rauc" "$CH/usr/lib/osmium" "$CH/etc/modules-load.d"
install -m 0644 "$KEYRING" "$CH/etc/rauc/keyring.pem"
# OTA signing public key — baked at /etc/hifi-player/ota-pubkey.pem so the device
# verifies the .img OTA payload (hifi-os-update.sh) and the VU/anim stores against
# it. The x86 live-build stages this in build-distro.sh; this debootstrap path must
# do it here or runtime OTA verification fails with the pubkey missing.
OTA_PUBKEY="${OTA_PUBKEY:-$SCRIPT_DIR/ota-keys/ota-pubkey.pem}"
[ -f "$OTA_PUBKEY" ] || die "OTA public key missing: $OTA_PUBKEY"
mkdir -p "$CH/etc/hifi-player"
install -m 0644 "$OTA_PUBKEY" "$CH/etc/hifi-player/ota-pubkey.pem"
printf '# Osmium Sound: RAUC bundle streaming (rauc install https://...)\nnbd\n' \
    > "$CH/etc/modules-load.d/hifi-rauc.conf"
printf '%s\n' "$VERSION" > "$CH/usr/lib/osmium/IMAGE_VERSION"
# shellcheck disable=SC2016
in_chroot dpkg-query -W -f='${Package}\t${Version}\n' | sort > "$CH/usr/lib/osmium/packages.txt"
# shellcheck disable=SC2016
in_chroot dpkg-query -W -f='${Package}\n${Provides}\n' \
    | tr ',' '\n' | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u \
    > "$CH/usr/lib/osmium/packages-provided.txt"
# All kernel versions present (v8 + 2712): used by BUILD_INFO and the initrd loop.
mapfile -t KVERS < <(find "$CH/boot" -maxdepth 1 -name 'vmlinuz-*' | sed 's|.*/vmlinuz-||' | sort -V)
[ "${#KVERS[@]}" -ge 1 ] || die "no kernel in $CH/boot"
{
    echo "version=$VERSION"
    echo "built=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
    echo "git=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "kernels=${KVERS[*]}"
    echo "arch=$ARCH"
    echo "board=raspberry-pi-4-and-5"
} > "$CH/usr/lib/osmium/BUILD_INFO"
cp "$CH/var/lib/dpkg/status" "$CH/usr/lib/osmium/dpkg-status"

# SYSEXT_LEVEL pins add-ons to this exact image (see build-image.sh for the long
# story): systemd-sysext refuses an extension whose level does not match.
if grep -q '^SYSEXT_LEVEL=' "$CH/usr/lib/os-release" 2>/dev/null; then
    sed -i "s|^SYSEXT_LEVEL=.*|SYSEXT_LEVEL=$VERSION|" "$CH/usr/lib/os-release"
else
    printf 'SYSEXT_LEVEL=%s\n' "$VERSION" >> "$CH/usr/lib/os-release"
fi
# Enable the add-on machinery (timer + sysext), one at a time so a failure is not
# hidden, exactly as build-image.sh does.
_out=$(in_chroot systemctl enable hifi-ext-refresh.timer 2>&1) \
    || die "systemctl enable hifi-ext-refresh.timer: $_out"
if ! _out=$(in_chroot systemctl enable systemd-sysext.service 2>&1); then
    log "systemd-sysext.service not enable-able via systemctl ($_out), linking by hand"
    [ -f "$CH/usr/lib/systemd/system/systemd-sysext.service" ] \
        || die "systemd-sysext.service missing: systemd too old for add-ons"
    mkdir -p "$CH/etc/systemd/system/sysinit.target.wants"
    ln -sf /usr/lib/systemd/system/systemd-sysext.service \
        "$CH/etc/systemd/system/sysinit.target.wants/systemd-sysext.service"
fi
[ -L "$CH/etc/systemd/system/timers.target.wants/hifi-ext-refresh.timer" ] \
    || die "hifi-ext-refresh.timer not enabled: add-ons would not be rebuilt after an update"
in_chroot systemctl enable systemd-timesyncd.service >/dev/null 2>&1 || true
[ -L "$CH/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service" ] \
    || log "WARNING: systemd-timesyncd not enabled: time would come only from the (absent) RTC"
mkdir -p "$CH/var/lib/extensions" "$CH/usr/share/factory/var/lib/hifi-player/ext"

# hifi-ext.sh builds add-ons as arm64 .debs now.
sed -i 's/DPKG_MAINTSCRIPT_ARCH=amd64/DPKG_MAINTSCRIPT_ARCH=arm64/g' \
    "$CH/usr/local/sbin/hifi-ext.sh" 2>/dev/null || true

# The interface must be present and must be Qt (eglfs/KMS, same as x86 default).
mkdir -p "$CH/etc/hifi-player"
printf 'qt\n' > "$CH/etc/hifi-player/ui-engine"
[ -x "$CH/opt/hifi-qt/hifi-qt" ] || die "missing /opt/hifi-qt/hifi-qt in the chroot"

# ── 5b. firmware slimming (arm-aware) ─────────────────────────────────────
# 🚨 Never touch a Wi-Fi/Bluetooth firmware the Pi uses (brcm/cypress for the
# on-board radio). Only drop datacenter NICs, discrete-GPU and foreign-platform
# blobs that a Pi can never use.
log "removing irrelevant firmware blobs (keeping brcm/cypress for the Pi radio)"
for d in netronome nvidia liquidio cxgb3 cxgb4 bnx2x qed mellanox mlxsw \
         myricom qlogic tehuti ueagle-atm i915 amdgpu radeon intel/ice; do
    rm -rf "${CH:?}/usr/lib/firmware/$d"
done

# ── 6. initrd (arm64, one per kernel): overlay/vfat/squashfs, plymouth ────
log "building the image initrd for each kernel (MODULES=most, plymouth)"
chmod +x "$CH/etc/initramfs-tools/hooks/hifi-state" \
    "$CH/etc/initramfs-tools/scripts/local-bottom/hifi-state" \
    "$CH/etc/initramfs-tools/scripts/local-premount/hifi-data-grow" \
    "$CH/usr/local/share/hifi-ab/initramfs/hooks/hifi-ab" \
    "$CH/usr/local/share/hifi-ab/initramfs/scripts/local-premount/hifi-ab-convert" 2>/dev/null || true
chmod 0755 "$CH"/usr/local/sbin/hifi-*.sh "$CH"/usr/local/sbin/hifi-*.py "$CH"/usr/local/bin/*.py 2>/dev/null || true
chmod +x "$CH/usr/local/bin/apt" 2>/dev/null || true
mkdir -p "$CH/etc/initramfs-tools/conf.d"
# gzip (NOT zstd): the factory initramfs must read the root squashfs, and the
# squashfs-zstd decompressor is not pulled into the initrd (same trap the Pi3
# build hit on 2.6.0-pi.13). gzip root + gzip-capable initrd is the safe pair.
cat > "$CH/etc/initramfs-tools/conf.d/hifi-image.conf" <<'CONF'
# Osmium Sound (Pi4/Pi5) — factory-built slot initrd: must boot any unit of the
# fleet (MODULES=most), with overlayfs for /etc, vfat for the FAT boot part,
# squashfs for the root, and plymouth (FRAMEBUFFER=y).
MODULES=most
COMPRESS=gzip
FRAMEBUFFER=y
CONF
for m in overlay squashfs vfat nls_cp437 nls_ascii nls_utf8 ext4 vc4 v3d; do
    grep -qx "$m" "$CH/etc/initramfs-tools/modules" 2>/dev/null || echo "$m" >> "$CH/etc/initramfs-tools/modules"
done
in_chroot plymouth-set-default-theme hifi 2>&1 | tail -n 3 || true
for KVER in "${KVERS[@]}"; do
    rm -f "$CH/boot/initrd.img-$KVER"
    in_chroot update-initramfs -c -k "$KVER" 2>&1 | tail -n 15 || true
    [ -s "$CH/boot/initrd.img-$KVER" ] || die "initrd not produced for $KVER"
    if command -v lsinitramfs >/dev/null 2>&1; then
        lsinitramfs "$CH/boot/initrd.img-$KVER" > "$WORK/initrd.list" 2>"$WORK/initrd.err" \
            || { cat "$WORK/initrd.err" >&2; die "cannot list the initrd ($KVER)"; }
    else
        in_chroot lsinitramfs "/boot/initrd.img-$KVER" > "$WORK/initrd.list" 2>"$WORK/initrd.err" \
            || { cat "$WORK/initrd.err" >&2; die "cannot list the initrd ($KVER)"; }
    fi
    log "initrd $KVER: $(wc -l < "$WORK/initrd.list") entries, $(du -h "$CH/boot/initrd.img-$KVER" | cut -f1)"
    for must in "scripts/local-bottom/hifi-state" "overlay" "bin/busybox" "sbin/e2fsck" "bin/plymouth"; do
        grep -qE "$must" "$WORK/initrd.list" \
            || { grep -E "hifi|busybox|e2fsck|overlay|plymouth" "$WORK/initrd.list" | head -n 20 >&2; die "the initrd ($KVER) is missing $must"; }
    done
done

# ── 7. fstab, machine-id (no slot grub.cfg: the Pi firmware boots directly) ─
cat > "$CH/etc/fstab" <<'FSTAB'
# /etc/fstab — Osmium Sound image (Pi4/Pi5, A/B slot, read-only squashfs root).
tmpfs  /mnt    tmpfs  mode=0755,nosuid,nodev  0  0
tmpfs  /media  tmpfs  mode=0755,nosuid,nodev  0  0
FSTAB
: > "$CH/etc/machine-id"
rm -f "$CH/var/lib/dbus/machine-id"

# ── 8. cleanup ────────────────────────────────────────────────────────────
log "cleanup (apt, doc/man/info, locale, log)"
[ -f "$SCRIPT_DIR/gen-credits.py" ] && { python3 "$SCRIPT_DIR/gen-credits.py" "$CH" "$CH/usr/lib/osmium/credits.json" || log "WARNING: gen-credits.py failed (non-fatal)"; }
in_chroot apt-get clean >/dev/null 2>&1 || true
rm -rf "$CH"/var/lib/apt/lists/* "$CH"/var/cache/apt/*.bin "$CH"/var/cache/debconf/*-old "$CH"/var/lib/dpkg/*-old
find "$CH/usr/share/doc" -mindepth 2 -type f ! -name copyright -delete 2>/dev/null || true
find "$CH/usr/share/doc" -mindepth 1 -type d -empty -delete 2>/dev/null || true
rm -rf "$CH"/usr/share/man/* "$CH"/usr/share/info/* "$CH"/usr/share/lintian
find "$CH/usr/share/locale" -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name 'it*' -exec rm -rf {} + 2>/dev/null || true
find "$CH/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf "$CH"/tmp/* "$CH"/var/tmp/* "$CH"/root/.cache "$CH"/root/.bash_history
rm -f "$CH/usr/sbin/policy-rc.d" "$CH/usr/bin/qemu-aarch64-static"
if [ -f "$WORK/resolv.conf.orig" ]; then cp -a "$WORK/resolv.conf.orig" "$CH/etc/resolv.conf"; else rm -f "$CH/etc/resolv.conf"; ln -s /run/NetworkManager/resolv.conf "$CH/etc/resolv.conf"; fi
for m in "$CH/run" "$CH/dev/pts" "$CH/dev" "$CH/sys" "$CH/proc"; do mountpoint -q "$m" && umount -R "$m"; done

used_mib=$(du -sxm "$CH" | cut -f1)
log "image content: ${used_mib} MiB"

# ── 9. rootfs.squashfs (read-only, gzip) ──────────────────────────────────
log "mksquashfs (gzip -9, 256K blocks)"
SQ="$WORK/rootfs.squashfs"; rm -f "$SQ"
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" mksquashfs "$CH" "$SQ" -comp gzip -Xcompression-level 9 -b 256K \
    -noappend -no-progress -xattrs -no-recovery >/dev/null || die "mksquashfs failed"
sq_mib=$(du -m "$SQ" | cut -f1)
budget=$(( SLOT_MIB * 90 / 100 ))
log "rootfs.squashfs: ${sq_mib} MiB (slot ${SLOT_MIB} MiB, cap ${budget})"
if [ "$sq_mib" -gt "$budget" ]; then
    du -xm --max-depth=2 "$CH" | sort -n | tail -n 15 >&2
    die "image over the cap: ${sq_mib} > ${budget} MiB"
fi

# ── 10. RAUC bundle (or just the rootfs) ──────────────────────────────────
if [ "$NO_BUNDLE" = 1 ]; then
    SQ_OUT="$OUT/osmium-rpi-${VERSION}.rootfs.squashfs"
    mv "$SQ" "$SQ_OUT"
    ( cd "$OUT" && sha256sum "$(basename "$SQ_OUT")" > "$(basename "$SQ_OUT").sha256" )
    cp "$CH/usr/lib/osmium/BUILD_INFO" "$OUT/osmium-rpi-${VERSION}.build-info.txt"
    log "DONE ✓  $SQ_OUT (no bundle)"
    exit 0
fi

[ -n "$CERT" ] && [ -n "$KEY" ] || die "--cert and --key are required to sign the bundle (or pass --no-bundle)"
log "rauc bundle (verity)"
B="$WORK/bundle"; mkdir -p "$B"
sed -e "s|@VERSION@|$VERSION|g" "$SCRIPT_DIR/rauc/manifest.raucm.tmpl" > "$B/manifest.raucm"
install -m 0755 "$SCRIPT_DIR/rauc/hook.sh" "$B/hook.sh"
mv "$SQ" "$B/rootfs.squashfs"
RAUCB="$OUT/osmium-rpi-${VERSION}.raucb"; rm -f "$RAUCB"
rauc bundle --cert "$CERT" --key "$KEY" --signing-keyring "$KEYRING" "$B" "$RAUCB" || die "rauc bundle failed"
rauc info --keyring "$KEYRING" "$RAUCB" > "$OUT/osmium-rpi-${VERSION}.info.txt" \
    || die "the bundle does not verify against the keyring $KEYRING"
( cd "$OUT" && sha256sum "$(basename "$RAUCB")" > "$(basename "$RAUCB").sha256" )
if [ "$KEEP_ROOTFS" = 1 ]; then cp "$B/rootfs.squashfs" "$OUT/osmium-rpi-${VERSION}.rootfs.squashfs"; fi
cp "$CH/usr/lib/osmium/BUILD_INFO" "$OUT/osmium-rpi-${VERSION}.build-info.txt"
log "DONE ✓  $RAUCB"
ls -lh "$OUT"/osmium-rpi-"${VERSION}".*
