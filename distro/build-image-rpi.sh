#!/usr/bin/env bash
#
# build-image-rpi.sh — a flashable SD/USB image for the Raspberry Pi 4 AND Pi 5
# (one image, both boards) from a rootfs.squashfs produced by build-rpi.sh.
#
#   sudo ./build-image-rpi.sh --rootfs osmium-rpi-2.5.26-....rootfs.squashfs \
#                             --out    osmium-rpi-2.5.26-....img
#
# Boot chain = the Raspberry Pi firmware tryboot A/B scheme (NOT U-Boot, which
# cannot drive the Pi5), so the table is GPT, not MBR:
#
#   p1 FAT32 hifi-rpifw   selector: autoboot.txt (+ firmware as fallback). The
#                         EEPROM reads autoboot.txt here and jumps to the boot
#                         FAT it names ([all] boot_partition=2 → p2 = slot A).
#   p2 FAT32 hifi-boot-a  slot A boot: firmware, kernel8.img (Pi4) + kernel_2712
#   p3 FAT32 hifi-boot-b  slot B boot: (Pi5), initramfs8/initramfs_2712, every
#                         bcm2711-*/bcm2712-* DTB + overlays/, config.txt, and a
#                         per-slot cmdline.txt (root=PARTUUID=… rauc.slot=A|B).
#   p4 raw   hifi-root-a  slot A: the rootfs.squashfs, block for block.
#   p5 raw   hifi-root-b  slot B: empty, filled by the first RAUC/OTA update.
#   p6 ext4  hifi-data    16 MiB seed; the initramfs grows it to fill the card.
#
# The firmware auto-selects kernel8.img on a Pi4 (BCM2711) and kernel_2712.img on
# a Pi5 (BCM2712), and the matching DTB, so the single image boots both. The RAUC
# custom backend (hifi-rpi-boot.sh) edits autoboot.txt to arm tryboot; the bundle
# hook (rauc/hook.sh) assembles slot B's boot FAT on the first update, using the
# SAME hifi-rpi-bootfat.sh this script calls — factory and OTA FATs stay identical.
#
# 🚨 GPT + boot_partition needs a recent EEPROM (rpi-eeprom ≥ 2025-03-10) and the
# downstream Raspberry kernel/firmware (installed by build-rpi.sh). Needs root.
# Host tools: sfdisk, losetup (partscan), mkfs.vfat (dosfstools), mkfs.ext4,
# blkid, mount (squashfs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/config/includes.chroot/usr/local/sbin/hifi-ab-lib.sh"
BOOTFAT_SH="$SCRIPT_DIR/config/includes.chroot/usr/local/sbin/hifi-rpi-bootfat.sh"
RPI_BOOT_DIR="$SCRIPT_DIR/rpi-boot"
ROOTFS=""
OUT=""
DATA_SEED_MIB=16
FW_MIB=32           # p1 selector: autoboot.txt + firmware fallback
BOOT_MIB=256        # p2/p3 per-slot boot FAT (2 kernels + 2 initramfs + DTBs/overlays)

# Fixed GPT GUIDs so PARTUUIDs are stable across builds (cmdline root=PARTUUID=…).
DISK_GUID="0a5e0501-0000-4000-8000-0000000000ff"
UUID_RPIFW="0a5e0501-0001-4000-8000-000000000001"
UUID_BOOTA="0a5e0501-0002-4000-8000-000000000002"
UUID_BOOTB="0a5e0501-0003-4000-8000-000000000003"
UUID_ROOTA="0a5e0501-0004-4000-8000-000000000004"
UUID_ROOTB="0a5e0501-0005-4000-8000-000000000005"
UUID_DATA="0a5e0501-0006-4000-8000-000000000006"
# GPT partition type GUIDs.
TYPE_FAT="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"   # Microsoft basic data (FAT)
TYPE_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4" # Linux filesystem

log() { printf '\033[1;36m[hifi-rpi-image]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[hifi-rpi-image ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --rpi-boot-dir) RPI_BOOT_DIR="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ "$(id -u)" -eq 0 ] || die "needs root"
[ -f "$ROOTFS" ] || die "--rootfs: no such file: $ROOTFS"
[ -n "$OUT" ] || die "--out missing"
[ -f "$RPI_BOOT_DIR/config.txt" ]      || die "missing $RPI_BOOT_DIR/config.txt"
[ -f "$RPI_BOOT_DIR/cmdline.txt.tmpl" ] || die "missing $RPI_BOOT_DIR/cmdline.txt.tmpl"
[ -x "$BOOTFAT_SH" ] || [ -f "$BOOTFAT_SH" ] || die "missing $BOOTFAT_SH"
# shellcheck source=distro/config/includes.chroot/usr/local/sbin/hifi-ab-lib.sh
# shellcheck disable=SC1091
. "$LIB"
for t in losetup sfdisk mount umount truncate mkfs.vfat mkfs.ext4 blkid; do
    command -v "$t" >/dev/null || die "$t missing on the build host"
done

img_bytes=$(stat -c %s "$ROOTFS")
[ "$img_bytes" -le $(( AB_SLOT_B_MIB * 1048576 )) ] \
    || die "the system image ($(( img_bytes / 1048576 )) MiB) does not fit a ${AB_SLOT_B_MIB} MiB slot"

WORK="$(mktemp -d "${IMAGE_WORK:-/var/tmp}/hifi-rpi-image.XXXXXX")"
MNT_SQ="$WORK/slotA"; MNT_FW="$WORK/rpifw"; MNT_BOOT="$WORK/boot"
mkdir -p "$MNT_SQ" "$MNT_FW" "$MNT_BOOT"
LOOP=""
cleanup() {
    set +e
    for m in "$MNT_BOOT" "$MNT_FW" "$MNT_SQ"; do mountpoint -q "$m" && umount -R "$m" 2>/dev/null; done
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── 1. the empty disk and its GPT ────────────────────────────────────────
total_mib=$(( 1 + FW_MIB + BOOT_MIB * 2 + AB_SLOT_B_MIB * 2 + DATA_SEED_MIB + 1 ))
log "disk image: ${total_mib} MiB (fw ${FW_MIB}, boot ${BOOT_MIB}×2, slots ${AB_SLOT_B_MIB}×2, system image $(( img_bytes / 1048576 )) MiB)"
rm -f "$OUT"
truncate -s "${total_mib}M" "$OUT"
sfdisk --quiet "$OUT" <<EOF || die "sfdisk failed"
label: gpt
label-id: $DISK_GUID
size=${FW_MIB}MiB,   type=$TYPE_FAT,   name="hifi-rpifw", uuid=$UUID_RPIFW
size=${BOOT_MIB}MiB, type=$TYPE_FAT,   name="hifi-boot-a", uuid=$UUID_BOOTA
size=${BOOT_MIB}MiB, type=$TYPE_FAT,   name="hifi-boot-b", uuid=$UUID_BOOTB
size=${AB_SLOT_B_MIB}MiB, type=$TYPE_LINUX, name="hifi-root-a", uuid=$UUID_ROOTA
size=${AB_SLOT_B_MIB}MiB, type=$TYPE_LINUX, name="hifi-root-b", uuid=$UUID_ROOTB
type=$TYPE_LINUX, name="hifi-data", uuid=$UUID_DATA
EOF

# ── 2. attach as a loop device, partitions included ──────────────────────
mknod_missing() {
    _n=$(basename "$1"); [ -b "/dev/$_n" ] && return 0
    _mm=$(cat "$1/dev"); mknod "/dev/$_n" b "${_mm%%:*}" "${_mm##*:}"
}
if ! LOOP=$(losetup --find --show --partscan "$OUT" 2>/dev/null); then
    for i in $(seq 0 63); do [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i"; done
    LOOP=$(losetup --find --show --partscan "$OUT") || die "no free loop device"
fi
ln=$(basename "$LOOP")
for i in $(seq 1 20); do
    [ -d "/sys/block/$ln/${ln}p6" ] && break
    partx -a "$LOOP" 2>/dev/null || true; sleep 0.5
done
[ -d "/sys/block/$ln/${ln}p6" ] || die "the kernel did not pick up the 6 partitions of $LOOP"
for p in /sys/block/"$ln"/"$ln"p*; do mknod_missing "$p"; done
log "attached as $LOOP"

P_RPIFW="${LOOP}p1"; P_BOOTA="${LOOP}p2"; P_BOOTB="${LOOP}p3"
P_ROOTA="${LOOP}p4"; P_ROOTB="${LOOP}p5"; P_DATA="${LOOP}p6"

# ── 3. slot A: the system image, block for block ─────────────────────────
log "writing the system image into slot A (p4 = hifi-root-a)"
dd if="$ROOTFS" of="$P_ROOTA" bs=4M conv=fsync status=none || die "writing slot A failed"

# PARTUUID of slot A's root partition → its cmdline.txt root=PARTUUID=…
ROOTA_PARTUUID=$(blkid -o value -s PARTUUID "$P_ROOTA" 2>/dev/null || true)
[ -n "$ROOTA_PARTUUID" ] || ROOTA_PARTUUID="$UUID_ROOTA"

# ── 4. inspect slot A (version) and assemble its boot FAT ────────────────
mount -t squashfs -o ro "$P_ROOTA" "$MNT_SQ" || die "slot A does not mount as squashfs"
img_ver=$(head -n 1 "$MNT_SQ/usr/lib/osmium/IMAGE_VERSION" 2>/dev/null || true)
[ -n "$img_ver" ] || die "$ROOTFS is not an Osmium system image (no IMAGE_VERSION)"
log "image $img_ver"

log "formatting the boot FATs and the selector FAT"
mkfs.vfat -F32 -n HIFIRPIFW "$P_RPIFW" >/dev/null || die "mkfs.vfat (p1) failed"
mkfs.vfat -F32 -n HIFIBOOTA "$P_BOOTA" >/dev/null || die "mkfs.vfat (p2) failed"
mkfs.vfat -F32 -n HIFIBOOTB "$P_BOOTB" >/dev/null || die "mkfs.vfat (p3) failed"

# Slot A boot FAT (p2): firmware + kernels + initramfs + DTBs + config/cmdline.
mount -t vfat -o rw,flush "$P_BOOTA" "$MNT_BOOT" || die "boot-a does not mount"
RPI_BOOT_DIR="$RPI_BOOT_DIR" sh "$BOOTFAT_SH" A "$MNT_SQ" "$MNT_BOOT" "$ROOTA_PARTUUID" \
    || die "assembling slot A boot FAT failed"
umount "$MNT_BOOT"
# Slot B boot FAT (p3): left empty on purpose — the first RAUC update that lands
# on slot B assembles it via rauc/hook.sh (same hifi-rpi-bootfat.sh).

# ── 5. selector FAT (p1 = hifi-rpifw): autoboot.txt + firmware fallback ───
mount -t vfat -o rw,flush "$P_RPIFW" "$MNT_FW" || die "selector FAT does not mount"
# Committed slot at factory = A → [all] boot_partition=2 ; candidate = 3. This is
# byte-for-byte what hifi-rpi-boot.sh's write_autoboot(A) rewrites, so arming and
# committing later never surprises the firmware.
cat > "$MNT_FW/autoboot.txt" <<'EOF'
# Osmium Sound A/B selector — managed by hifi-rpi-boot.sh. Do not hand-edit.
[all]
tryboot_a_b=1
boot_partition=2

[tryboot]
boot_partition=3
EOF
# Firmware fallback on the selector FAT (harmless; the boot FATs carry their own).
FW_DIR="$MNT_SQ/usr/lib/raspi-firmware"
[ -d "$FW_DIR" ] && cp -a "$FW_DIR"/*.elf "$FW_DIR"/*.dat "$FW_DIR"/*.bin "$MNT_FW/" 2>/dev/null || true
sync
umount "$MNT_FW"
umount "$MNT_SQ"

# ── 6. data partition (p6 = hifi-data): ext4 seed, grown on first boot ────
log "formatting the data seed (p6 = hifi-data)"
mkfs.ext4 -q -L hifi-data -F "$P_DATA" || die "mkfs.ext4 (data) failed"

sync
losetup -d "$LOOP"; LOOP=""

# ── 7. sanity: the GPT partition names, in order ─────────────────────────
names=$(sfdisk -d "$OUT" | sed -n 's/.*name="\([^"]*\)".*/\1/p' | tr '\n' ',')
want="hifi-rpifw,hifi-boot-a,hifi-boot-b,hifi-root-a,hifi-root-b,hifi-data,"
[ "$names" = "$want" ] || die "unexpected GPT layout: $names (want $want)"
log "DONE ✓  $OUT ($img_ver, ${total_mib} MiB, GPT tryboot A/B)"
