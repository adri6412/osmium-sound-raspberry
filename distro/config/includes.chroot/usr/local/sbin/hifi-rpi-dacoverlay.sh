#!/bin/sh
# shellcheck shell=sh
# Osmium Sound — inject the chosen I2S HAT overlay into a boot config.txt.
#
#   hifi-rpi-dacoverlay.sh <config.txt-path> [<overlay-value>]
#
# <overlay-value> is the dtoverlay payload WITHOUT the `dtoverlay=` prefix, e.g.
# "hifiberry-dacplus" or "allo-boss-dac-pcm512x-audio,slave". Empty / omitted =
# no HAT (the managed block is left with no dtoverlay line → USB/HDMI only).
#
# This is the SINGLE renderer for both write paths:
#   - hifi-rpi-bootfat.sh re-injects the saved choice every time it regenerates
#     the boot FAT (factory build + every OTA), so the choice survives updates;
#   - api_server (/set_dac_hat) applies a runtime change to the live boot FAT(s).
# It rewrites ONLY the block between the "# >>> osmium-dac" and "# <<< osmium-dac"
# markers, so it is idempotent: running it again replaces the same block. If the
# markers are absent (an old config.txt) the block is appended once.
set -eu

CFG="${1:?config.txt path}"
VALUE="${2:-}"
[ -f "$CFG" ] || { printf 'E: [hifi-rpi-dacoverlay] no config.txt at %s\n' "$CFG" >&2; exit 1; }

BEGIN='# >>> osmium-dac'
END='# <<< osmium-dac'
TMP="$CFG.dac.$$"
trap 'rm -f "$TMP"' EXIT

# Caller passes the payload only; tolerate a stray dtoverlay= prefix, then allow
# just the overlay charset (letters, digits, and , . _ = -). This rejects
# newlines, spaces and shell metacharacters outright.
case "$VALUE" in dtoverlay=*) VALUE="${VALUE#dtoverlay=}" ;; esac
case "$VALUE" in
    *[!A-Za-z0-9,._=-]*)
        printf 'E: [hifi-rpi-dacoverlay] invalid overlay value: %s\n' "$VALUE" >&2
        exit 1 ;;
esac

awk -v b="$BEGIN" -v e="$END" -v val="$VALUE" '
    BEGIN { inblk = 0; seen = 0 }
    $0 == b {
        inblk = 1; seen = 1
        print b
        print "# I2S HAT overlay — managed by hifi-rpi-dacoverlay.sh, do NOT edit by hand."
        if (val != "") print "dtoverlay=" val
        next
    }
    $0 == e { inblk = 0; print e; next }
    inblk == 1 { next }   # drop old block body
    { print }
    END {
        if (seen == 0) {   # no markers in the file: append a fresh block
            print b
            print "# I2S HAT overlay — managed by hifi-rpi-dacoverlay.sh, do NOT edit by hand."
            if (val != "") print "dtoverlay=" val
            print e
        }
    }
' "$CFG" > "$TMP"

cat "$TMP" > "$CFG"   # preserve ownership/permissions of the original file
sync 2>/dev/null || true
if [ -n "$VALUE" ]; then
    printf 'I: [hifi-rpi-dacoverlay] %s -> dtoverlay=%s\n' "$CFG" "$VALUE" >&2
else
    printf 'I: [hifi-rpi-dacoverlay] %s -> no HAT overlay\n' "$CFG" >&2
fi
