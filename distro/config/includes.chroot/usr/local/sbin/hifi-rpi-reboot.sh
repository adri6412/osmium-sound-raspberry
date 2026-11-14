#!/bin/sh
# shellcheck shell=sh
# Osmium Sound — reboot helper for the Raspberry Pi firmware tryboot A/B scheme.
#
#   hifi-rpi-reboot.sh --auto      reboot into tryboot IFF a slot is pending
#                                  (armed by `rauc install` → set-primary),
#                                  otherwise a normal reboot.
#   hifi-rpi-reboot.sh --tryboot   force a one-shot tryboot reboot now.
#   hifi-rpi-reboot.sh --normal    force a normal reboot now.
#
# The OTA apply path calls `--auto` after installing a bundle so the freshly
# written slot is booted ONCE via the firmware's [tryboot] section; if it fails
# to come up, the firmware falls back to the committed slot on the next reset.
# A normal `reboot` would boot the still-committed (old) slot, so the updater
# must use this wrapper rather than plain reboot on the Pi.
#
# `reboot "0 tryboot"` is the documented trigger (the downstream Pi kernel
# passes the argument to the firmware). 🚨 VERIFY on hardware: if the kernel in
# use ignores the reboot argument, arm tryboot via vcmailbox instead
# (0x00038064 — see the commented fallback below) before the reboot.
set -eu

PENDING="/run/hifi-rpifw/pending-slot"
SELFW_LABEL="hifi-rpifw"

has_pending() {
    # The marker lives on the selector FAT; mount read-only to peek if needed.
    [ -f "$PENDING" ] && return 0
    _d="/dev/disk/by-partlabel/$SELFW_LABEL"
    [ -e "$_d" ] || return 1
    _m=$(mktemp -d)
    if mount -t vfat -o ro "$_d" "$_m" 2>/dev/null; then
        _r=1; [ -f "$_m/pending-slot" ] && _r=0
        umount "$_m" 2>/dev/null || true; rmdir "$_m" 2>/dev/null || true
        return $_r
    fi
    rmdir "$_m" 2>/dev/null || true
    return 1
}

do_tryboot() {
    # Preferred: pass "tryboot" to the firmware through the reboot syscall arg.
    if reboot "0 tryboot" 2>/dev/null; then exit 0; fi
    # Fallback: set the tryboot flag via the VideoCore mailbox, then reboot.
    # 🚨 Needs /dev/vcio (downstream kernel) and raspi-utils-core's vcmailbox.
    if command -v vcmailbox >/dev/null 2>&1; then
        vcmailbox 0x00038064 4 4 0 1 >/dev/null 2>&1 || true
    fi
    exec systemctl reboot
}

case "${1:---auto}" in
    --tryboot) do_tryboot ;;
    --normal)  exec systemctl reboot ;;
    --auto)
        if has_pending; then do_tryboot; else exec systemctl reboot; fi ;;
    *) echo "usage: $0 {--auto|--tryboot|--normal}" >&2; exit 2 ;;
esac
