#!/bin/sh
# Osmium Sound — RAUC bundle hook (travels inside the signed bundle).
#
#   install-check      reject the bundle if it is not for this hardware or if the
#                      device has no A/B layout (no data partition).
#   slot-post-install  after the new root slot is written: assemble THAT slot's
#                      boot FAT (kernel8/kernel_2712, initramfs, DTBs, overlays,
#                      config.txt, per-slot cmdline.txt) so the firmware can boot
#                      it. On the Pi the kernel lives on a FAT the firmware reads,
#                      not inside the squashfs, so every update must refresh it.
set -eu

# bootname (A|B) -> the GPT PARTLABEL of that slot's boot FAT.
bootfat_label() {
    case "$1" in
        A) echo hifi-boot-a ;;
        B) echo hifi-boot-b ;;
        *) echo "" ;;
    esac
}

case "${1:-}" in
install-check)
    if [ "${RAUC_MF_COMPATIBLE:-}" != "${RAUC_SYSTEM_COMPATIBLE:-}" ]; then
        echo "Bundle for '${RAUC_MF_COMPATIBLE:-?}', device is '${RAUC_SYSTEM_COMPATIBLE:-?}'" >&2
        exit 10
    fi
    if [ ! -e /dev/disk/by-partlabel/hifi-data ]; then
        echo "No data partition (hifi-data): device is not A/B-converted yet" >&2
        exit 11
    fi
    ;;
slot-post-install)
    case "${RAUC_SLOT_CLASS:-}" in
    rootfs)
        dev="${RAUC_SLOT_DEVICE:?}"
        boot="${RAUC_SLOT_BOOTNAME:?}"   # A or B, from system.conf
        label=$(bootfat_label "$boot")
        [ -n "$label" ] || { echo "unknown bootname '$boot'" >&2; exit 12; }
        fatdev="/dev/disk/by-partlabel/$label"
        [ -e "$fatdev" ] || { echo "boot FAT $label not found for slot $boot" >&2; exit 13; }

        # PARTUUID of the just-written root slot — goes into its cmdline.txt root=.
        rootdev=$(readlink -f "$dev")
        partuuid=$(blkid -o value -s PARTUUID "$rootdev" 2>/dev/null || true)
        [ -n "$partuuid" ] || { echo "no PARTUUID for $rootdev" >&2; exit 14; }

        tmp=$(mktemp -d)
        sqm="$tmp/sq"; fatm="$tmp/fat"; mkdir -p "$sqm" "$fatm"
        cleanup() {
            umount "$fatm" 2>/dev/null || true
            umount "$sqm" 2>/dev/null || true
            rmdir "$fatm" "$sqm" "$tmp" 2>/dev/null || true
        }
        trap cleanup EXIT

        mount -t squashfs -o ro "$rootdev" "$sqm" \
            || { echo "slot $boot does not mount as squashfs" >&2; exit 15; }
        mount -t vfat -o rw,flush "$fatdev" "$fatm" \
            || { echo "cannot mount boot FAT $label" >&2; exit 16; }

        # Same assembler the factory build uses, so OTA and factory FATs match.
        RPI_BOOT_DIR="$sqm/usr/local/share/hifi-ab/rpi-boot" \
            "$sqm/usr/local/sbin/hifi-rpi-bootfat.sh" "$boot" "$sqm" "$fatm" "$partuuid" \
            || { echo "assembling boot FAT for slot $boot failed" >&2; exit 17; }
        sync
        ;;
    esac
    ;;
*)
    exit 1
    ;;
esac
exit 0
