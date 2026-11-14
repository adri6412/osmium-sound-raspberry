#!/bin/sh
# shellcheck shell=sh
# Osmium Sound — RAUC "custom" bootloader backend for the Raspberry Pi 4 / Pi 5
# firmware tryboot A/B scheme. There is no official RAUC backend for the Pi
# bootloader (the upstream PRs are not merged), so this script implements the
# four operations RAUC's `bootloader=custom` calls, on top of autoboot.txt:
#
#   get-primary                -> prints the committed slot's bootname (A|B)
#   set-primary <A|B>          -> ARMS a one-shot tryboot of that slot
#   get-state   <A|B>          -> prints "good" or "bad"
#   set-state   <A|B> good|bad -> good commits a booted candidate; bad fences it
#
# Design (why tryboot and not just swapping the primary):
#   autoboot.txt (on p1, PARTLABEL hifi-rpifw) selects the boot FAT partition.
#   [all] boot_partition   = the COMMITTED slot (A=2, B=3): a normal reboot.
#   [tryboot] boot_partition = the CANDIDATE slot: used for ONE boot after a
#                              tryboot reset, then the firmware falls back to
#                              [all] by itself. That one-shot is our rollback —
#                              a broken new slot never becomes permanent.
#
# Flow: `rauc install` writes the inactive slot and calls `set-primary <new>`.
# We do NOT change [all]; we point [tryboot] at <new> and drop a pending marker.
# The updater then reboots via `hifi-rpi-reboot --auto`, which issues
# `reboot "0 tryboot"` because a pending marker exists, so the firmware boots
# <new> once. On <new>, hifi-boot-health runs `rauc status mark-good`, RAUC
# calls `set-state <new> good`, and THAT commits: [all] is rewritten to <new>.
# If <new> fails to boot, the next reset returns to the committed slot with no
# action needed.
#
# 🚨 autoboot.txt line format is edited by pattern; keep its keys verbatim
# (see distro/rpi-boot/autoboot.txt). Needs root (RAUC runs it as root).
set -eu

SELFW_LABEL="hifi-rpifw"
MNT="/run/hifi-rpifw"
AUTOBOOT="$MNT/autoboot.txt"
# Slot bootname -> its boot FAT partition number in autoboot.txt.
SLOT_A_PART=2
SLOT_B_PART=3

log() { printf 'I: [hifi-rpi-boot] %s\n' "$*" >&2; }
die() { printf 'E: [hifi-rpi-boot] %s\n' "$*" >&2; exit 1; }

# Resolve the selector FAT (p1) by GPT PARTLABEL on the root disk. Falls back to
# /dev/disk/by-partlabel, which udev populates from the same labels.
selfw_dev() {
    if [ -e "/dev/disk/by-partlabel/$SELFW_LABEL" ]; then
        readlink -f "/dev/disk/by-partlabel/$SELFW_LABEL"; return 0
    fi
    # shellcheck disable=SC1091
    . /usr/local/sbin/hifi-ab-lib.sh 2>/dev/null || true
    if command -v ab_part_by_name >/dev/null 2>&1; then
        ab_part_by_name "$SELFW_LABEL" && return 0
    fi
    return 1
}

mount_selfw() {
    mountpoint -q "$MNT" && return 0
    _d=$(selfw_dev) || die "selector FAT ($SELFW_LABEL) not found"
    mkdir -p "$MNT"
    mount -t vfat -o rw,flush "$_d" "$MNT" || die "cannot mount $_d at $MNT"
    [ -f "$AUTOBOOT" ] || die "no autoboot.txt on the selector FAT"
}
umount_selfw() { sync; mountpoint -q "$MNT" && umount "$MNT" || true; }

slot_part() { case "$1" in A) echo "$SLOT_A_PART" ;; B) echo "$SLOT_B_PART" ;; *) die "unknown slot '$1'" ;; esac; }
other_slot() { case "$1" in A) echo B ;; B) echo A ;; *) die "unknown slot '$1'" ;; esac; }

# The committed slot = the boot_partition in the [all] section.
committed_slot() {
    _p=$(awk '
        /^\[all\]/      { s=1; next }
        /^\[tryboot\]/  { s=0; next }
        /^\[/           { s=0; next }
        s && /^[[:space:]]*boot_partition[[:space:]]*=/ { gsub(/[^0-9]/,""); print; exit }
    ' "$AUTOBOOT")
    case "$_p" in
        "$SLOT_A_PART") echo A ;;
        "$SLOT_B_PART") echo B ;;
        *) echo A ;;   # safe default
    esac
}

# Rewrite autoboot.txt so [all]=<commit> and [tryboot]=<the other>. Rebuilt from
# a fixed template (not sed-in-place) so a hand-edited file cannot drift.
write_autoboot() {   # <committed-slot>
    _commit="$1"; _cp=$(slot_part "$_commit"); _tp=$(slot_part "$(other_slot "$_commit")")
    _tmp="$AUTOBOOT.new"
    cat > "$_tmp" <<EOF
# Osmium Sound A/B selector — managed by hifi-rpi-boot.sh. Do not hand-edit.
[all]
tryboot_a_b=1
boot_partition=$_cp

[tryboot]
boot_partition=$_tp
EOF
    sync
    mv -f "$_tmp" "$AUTOBOOT"
    sync
}

# Arm a one-shot tryboot of <cand>: [tryboot] points at it, a pending marker
# records it. [all] (the committed slot) is left untouched.
arm_tryboot() {   # <candidate-slot>
    _cand="$1"; _commit=$(committed_slot)
    if [ "$_cand" = "$_commit" ]; then
        # Activating the already-committed slot: nothing to try, clear pending.
        rm -f "$MNT/pending-slot"
        write_autoboot "$_commit"
        return 0
    fi
    _cp=$(slot_part "$_commit"); _tp=$(slot_part "$_cand")
    _tmp="$AUTOBOOT.new"
    cat > "$_tmp" <<EOF
# Osmium Sound A/B selector — managed by hifi-rpi-boot.sh. Do not hand-edit.
[all]
tryboot_a_b=1
boot_partition=$_cp

[tryboot]
boot_partition=$_tp
EOF
    sync; mv -f "$_tmp" "$AUTOBOOT"
    printf '%s\n' "$_cand" > "$MNT/pending-slot"
    sync
    log "armed tryboot of slot $_cand (committed stays $_commit); reboot with tryboot to try it"
}

cmd=${1:-}; shift 2>/dev/null || true
case "$cmd" in
    get-primary)
        mount_selfw; committed_slot; umount_selfw ;;
    set-primary)
        [ $# -ge 1 ] || die "set-primary needs a slot"
        mount_selfw; arm_tryboot "$1"; umount_selfw ;;
    get-state)
        [ $# -ge 1 ] || die "get-state needs a slot"
        mount_selfw
        if [ -f "$MNT/slot-$1.bad" ]; then echo bad; else echo good; fi
        umount_selfw ;;
    set-state)
        [ $# -ge 2 ] || die "set-state needs <slot> <good|bad>"
        _slot="$1"; _st="$2"; mount_selfw
        case "$_st" in
            good)
                rm -f "$MNT/slot-$_slot.bad"
                # Commit if this booted slot is the pending candidate.
                if [ -f "$MNT/pending-slot" ] && [ "$(cat "$MNT/pending-slot")" = "$_slot" ]; then
                    write_autoboot "$_slot"
                    rm -f "$MNT/pending-slot"
                    log "committed slot $_slot as permanent"
                fi
                ;;
            bad)
                : > "$MNT/slot-$_slot.bad"
                log "slot $_slot marked bad"
                ;;
            *) umount_selfw; die "state must be good or bad" ;;
        esac
        sync; umount_selfw ;;
    *)
        die "usage: $0 {get-primary|set-primary <slot>|get-state <slot>|set-state <slot> good|bad}" ;;
esac
