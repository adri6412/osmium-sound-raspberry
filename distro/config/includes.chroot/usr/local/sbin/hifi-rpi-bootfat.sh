#!/bin/sh
# shellcheck shell=sh
# Osmium Sound — assemble the boot FAT for one A/B slot (Raspberry Pi 4 + Pi 5).
#
#   hifi-rpi-bootfat.sh <A|B> <rootfs-mountpoint> <bootfat-mountpoint> <root-partuuid>
#
# Both the factory build (build-image-rpi.sh) and the per-OTA RAUC hook
# (distro/rauc/hook.sh, slot-post-install) call this so the two paths produce an
# identical boot partition. The CALLER mounts the read-only squashfs rootfs and
# the writable boot FAT and passes their mountpoints — mounting differs between
# the build host and the device, the assembly does not.
#
# It lays down, from primary sources in the rootfs (never trusting a possibly
# incomplete /boot/firmware):
#   - the VideoCore firmware     (/usr/lib/raspi-firmware/*)
#   - kernel8.img  (Pi 4, the -v8 kernel)   + kernel_2712.img (Pi 5, -2712)
#   - initramfs8   (Pi 4)                    + initramfs_2712  (Pi 5)
#   - every bcm2711-*/bcm2712-* DTB + the overlays/ directory
#   - config.txt   (shared template) and cmdline.txt (rendered: root= + rauc.slot=)
#
# 🚨 Kernel flavour suffixes are "-rpi-v8" (Pi 4 / BCM2711) and "-rpi-2712"
# (Pi 5 / BCM2712). VERIFY on the first build that the Pi archive names them so;
# the asserts below fail loudly if a flavour is missing rather than ship a FAT
# that boots only one board.
set -eu

SLOT="${1:?slot A|B}"; SQ="${2:?rootfs mountpoint}"; FAT="${3:?boot FAT mountpoint}"
ROOT_PARTUUID="${4:?root PARTUUID}"
RPI_BOOT_DIR="${RPI_BOOT_DIR:-/usr/local/share/hifi-ab/rpi-boot}"

log() { printf 'I: [hifi-rpi-bootfat] %s\n' "$*" >&2; }
die() { printf 'E: [hifi-rpi-bootfat] %s\n' "$*" >&2; exit 1; }

[ -d "$SQ/boot" ] || die "no /boot in the rootfs at $SQ"
[ -d "$FAT" ] || die "boot FAT mountpoint $FAT does not exist"
[ -f "$RPI_BOOT_DIR/config.txt" ] || die "missing config.txt template in $RPI_BOOT_DIR"
[ -f "$RPI_BOOT_DIR/cmdline.txt.tmpl" ] || die "missing cmdline.txt.tmpl in $RPI_BOOT_DIR"

# ── VideoCore firmware ────────────────────────────────────────────────────
FW="$SQ/usr/lib/raspi-firmware"
[ -d "$FW" ] || die "raspi-firmware not installed in the rootfs ($FW)"
cp -a "$FW"/*.elf "$FW"/*.dat "$FAT"/ 2>/dev/null || true
cp -a "$FW"/*.bin "$FAT"/ 2>/dev/null || true

# ── kernels + initramfs, by flavour ───────────────────────────────────────
copy_flavour() {   # <flavour-suffix> <kernel-dest> <initramfs-dest>
    _fl="$1"; _kd="$2"; _id="$3"
    _vmlinuz=$(ls -1 "$SQ"/boot/vmlinuz-*"$_fl" 2>/dev/null | sort -V | tail -n 1 || true)
    _initrd=$(ls -1 "$SQ"/boot/initrd.img-*"$_fl" 2>/dev/null | sort -V | tail -n 1 || true)
    [ -n "$_vmlinuz" ] || die "no kernel for flavour '$_fl' in the rootfs (need $_kd)"
    [ -n "$_initrd" ]  || die "no initramfs for flavour '$_fl' in the rootfs (need $_id)"
    cp -a "$_vmlinuz" "$FAT/$_kd"
    cp -a "$_initrd"  "$FAT/$_id"
    log "$_kd / $_id  ←  $(basename "$_vmlinuz")"
    # DTBs + overlays ship beside this kernel's modules, under
    # /usr/lib/linux-image-<kver>/broadcom (kver = vmlinuz basename minus prefix).
    # overlays/ may sit under broadcom/ or one level up, depending on the kernel
    # package — copy whichever exists. (Plain `test && {…}` would abort the whole
    # script under `set -e` when the dir is absent, so use if/then.)
    _dtbdir="$SQ/usr/lib/linux-image-$(basename "$_vmlinuz" | sed 's/^vmlinuz-//')"
    if [ -d "$_dtbdir/broadcom" ]; then
        cp -a "$_dtbdir"/broadcom/*.dtb "$FAT"/ 2>/dev/null || true
    fi
    for _ov in "$_dtbdir/broadcom/overlays" "$_dtbdir/overlays"; do
        if [ -d "$_ov" ]; then
            mkdir -p "$FAT/overlays"
            cp -a "$_ov"/* "$FAT/overlays/" 2>/dev/null || true
        fi
    done
}
copy_flavour "-rpi-v8"   "kernel8.img"      "initramfs8"
copy_flavour "-rpi-2712" "kernel_2712.img"  "initramfs_2712"

# Fallback DTB/overlay source: whatever the packages already staged in
# /boot/firmware (harmless if absent; the asserts above already guaranteed DTBs).
if [ -d "$SQ/boot/firmware" ]; then
    cp -a "$SQ"/boot/firmware/*.dtb "$FAT"/ 2>/dev/null || true
    if [ -d "$SQ/boot/firmware/overlays" ]; then
        mkdir -p "$FAT/overlays"
        cp -a "$SQ"/boot/firmware/overlays/* "$FAT/overlays/" 2>/dev/null || true
    fi
fi
ls "$FAT"/bcm2711-*.dtb >/dev/null 2>&1 || die "no Pi 4 (bcm2711-*) DTB landed on the boot FAT"
ls "$FAT"/bcm2712-*.dtb >/dev/null 2>&1 || die "no Pi 5 (bcm2712-*) DTB landed on the boot FAT"

# ── config.txt (shared) + cmdline.txt (per slot) ──────────────────────────
cp -f "$RPI_BOOT_DIR/config.txt" "$FAT/config.txt"

# Re-inject the user-chosen I2S HAT overlay into the freshly copied config.txt,
# so the choice survives this regeneration (factory build AND every OTA). The
# choice lives on the shared /data overlay at /etc/hifi-player/dac-hat.conf
# (key=value lines; the `overlay=` line holds the dtoverlay payload). It is read
# from the LIVE /etc (same for both A/B slots), not from the read-only squashfs
# $SQ, whose /etc has no overlay upper layer. Absent (factory build) = no HAT.
DAC_HAT_CONF="${DAC_HAT_CONF:-/etc/hifi-player/dac-hat.conf}"
DAC_RENDER="$SQ/usr/local/sbin/hifi-rpi-dacoverlay.sh"
_dac_overlay=""
if [ -f "$DAC_HAT_CONF" ]; then
    _dac_overlay=$(sed -n 's/^overlay=//p' "$DAC_HAT_CONF" | head -n 1)
fi
if [ -x "$DAC_RENDER" ]; then
    sh "$DAC_RENDER" "$FAT/config.txt" "$_dac_overlay" \
        || die "failed to render the DAC overlay into config.txt"
else
    log "WARN: $DAC_RENDER missing; config.txt has no HAT overlay injected"
fi

# Same for the user-chosen DSI panel overlay (separate marker block, separate
# renderer). The choice lives at /etc/hifi-player/display-panel.conf
# (display=/touch= key=value lines). Absent (factory build) = no panel overlay.
DSI_PANEL_CONF="${DSI_PANEL_CONF:-/etc/hifi-player/display-panel.conf}"
DSI_RENDER="$SQ/usr/local/sbin/hifi-rpi-dsioverlay.sh"
_dsi_overlay=""
_dsi_touch=""
if [ -f "$DSI_PANEL_CONF" ]; then
    _dsi_overlay=$(sed -n 's/^display=//p' "$DSI_PANEL_CONF" | head -n 1)
    _dsi_touch=$(sed -n 's/^touch=//p' "$DSI_PANEL_CONF" | head -n 1)
fi
if [ -x "$DSI_RENDER" ]; then
    sh "$DSI_RENDER" "$FAT/config.txt" "$_dsi_overlay" "$_dsi_touch" \
        || die "failed to render the DSI panel overlay into config.txt"
else
    log "WARN: $DSI_RENDER missing; config.txt has no DSI panel overlay injected"
fi

sed -e "s|@ROOT_PARTUUID@|$ROOT_PARTUUID|g" -e "s|@SLOT@|$SLOT|g" \
    "$RPI_BOOT_DIR/cmdline.txt.tmpl" > "$FAT/cmdline.txt"
sync
log "slot $SLOT boot FAT ready (root=PARTUUID=$ROOT_PARTUUID)"
