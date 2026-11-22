#!/bin/sh
# shellcheck shell=sh
# Osmium Sound — inject the chosen DSI panel overlay into a boot config.txt.
#
#   hifi-rpi-dsioverlay.sh <config.txt-path> [<display-overlay-value>] [<touch-overlay-value>]
#
# Each overlay value is a dtoverlay payload WITHOUT the `dtoverlay=` prefix, e.g.
# "vc4-kms-dsi-waveshare-panel,7_0_inchC". Empty / omitted display value = no
# panel overlay (the managed block is left with no dtoverlay line → the firmware
# auto-detects the official Raspberry Pi panel, or nothing on HDMI-only setups).
# The optional touch value renders a SECOND dtoverlay line, for panels whose
# touch controller needs its own overlay; the common DSI panels bundle touch in
# the display overlay and leave it empty.
#
# This is the SINGLE renderer for both write paths, the twin of
# hifi-rpi-dacoverlay.sh:
#   - hifi-rpi-bootfat.sh re-injects the saved choice every time it regenerates
#     the boot FAT (factory build + every OTA), so the choice survives updates;
#   - api_server (/set_display_panel) applies a runtime change to the live boot
#     FAT(s).
# It rewrites ONLY the block between the "# >>> osmium-dsi" and "# <<< osmium-dsi"
# markers, so it is idempotent. If the markers are absent (an old config.txt) the
# block is appended once. It is kept SEPARATE from the "# >>> osmium-dac" block so
# DSI and the I2S HAT never overwrite each other.
set -eu

CFG="${1:?config.txt path}"
VALUE="${2:-}"
TOUCH="${3:-}"
[ -f "$CFG" ] || { printf 'E: [hifi-rpi-dsioverlay] no config.txt at %s\n' "$CFG" >&2; exit 1; }

BEGIN='# >>> osmium-dsi'
END='# <<< osmium-dsi'
TMP="$CFG.dsi.$$"
trap 'rm -f "$TMP"' EXIT

# Callers pass the payload only; tolerate a stray dtoverlay= prefix, then allow
# just the overlay charset (letters, digits, and , . _ = -). This rejects
# newlines, spaces and shell metacharacters outright.
for _v in "$VALUE" "$TOUCH"; do
    case "$_v" in dtoverlay=*) _v="${_v#dtoverlay=}" ;; esac
    case "$_v" in
        *[!A-Za-z0-9,._=-]*)
            printf 'E: [hifi-rpi-dsioverlay] invalid overlay value: %s\n' "$_v" >&2
            exit 1 ;;
    esac
done
case "$VALUE" in dtoverlay=*) VALUE="${VALUE#dtoverlay=}" ;; esac
case "$TOUCH" in dtoverlay=*) TOUCH="${TOUCH#dtoverlay=}" ;; esac

awk -v b="$BEGIN" -v e="$END" -v val="$VALUE" -v touch="$TOUCH" '
    function emit_block() {
        print "# DSI panel overlay — managed by hifi-rpi-dsioverlay.sh, do NOT edit by hand."
        if (val != "")   print "dtoverlay=" val
        if (touch != "") print "dtoverlay=" touch
    }
    BEGIN { inblk = 0; seen = 0 }
    $0 == b {
        inblk = 1; seen = 1
        print b
        emit_block()
        next
    }
    $0 == e { inblk = 0; print e; next }
    inblk == 1 { next }   # drop old block body
    { print }
    END {
        if (seen == 0) {   # no markers in the file: append a fresh block
            print b
            emit_block()
            print e
        }
    }
' "$CFG" > "$TMP"

cat "$TMP" > "$CFG"   # preserve ownership/permissions of the original file
sync 2>/dev/null || true
if [ -n "$VALUE" ]; then
    printf 'I: [hifi-rpi-dsioverlay] %s -> dtoverlay=%s%s\n' "$CFG" "$VALUE" \
        "$( [ -n "$TOUCH" ] && printf ' + dtoverlay=%s' "$TOUCH" )" >&2
else
    printf 'I: [hifi-rpi-dsioverlay] %s -> no DSI panel overlay\n' "$CFG" >&2
fi
