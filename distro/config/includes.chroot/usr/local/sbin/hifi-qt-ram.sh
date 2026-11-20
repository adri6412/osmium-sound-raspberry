#!/bin/sh
# Osmium Sound (Raspberry Pi fork) — stage the Qt on-screen UI payload in RAM.
#
# WHY
# The root filesystem is a read-only compressed squashfs. The Qt kiosk reads its
# QML and ~23 MB of assets (VU skins, Now Playing animations) lazily, so the
# first visit to each screen pays a page-fault + decompress — visible stutter on
# screen changes. Copying the whole /opt/hifi-qt payload (binary + qml + assets)
# into a tmpfs once at boot decompresses it all sequentially up front; every
# later access is a plain RAM read.
#
# ROBUSTNESS
# /run/hifi-qt is ALWAYS made a valid mount pointing at the payload:
#   - enough free RAM  -> tmpfs + full copy (the fast path);
#   - low RAM, or any copy failure -> bind mount of /opt/hifi-qt (same speed as
#     before, never worse).
# hifi-qt.service runs from /run/hifi-qt via a drop-in, so it works either way.
# Idempotent: a no-op if /run/hifi-qt is already a mount.
set -eu

SRC=/opt/hifi-qt
DEST=/run/hifi-qt
MIN_KB=768000          # need ~768 MB available before spending RAM on a copy
TMPFS_SIZE=256m

log() { printf 'hifi-qt-ram: %s\n' "$*" >&2; }

# Already staged (service re-run, manual start): nothing to do.
if mountpoint -q "$DEST" 2>/dev/null; then
    log "already mounted at $DEST"
    exit 0
fi

# No payload to stage: let hifi-qt.service surface the error itself.
if [ ! -x "$SRC/hifi-qt" ]; then
    log "no payload at $SRC, nothing to stage"
    exit 0
fi

mkdir -p "$DEST"

bind_fallback() {
    umount "$DEST" 2>/dev/null || true
    if mount --bind "$SRC" "$DEST"; then
        log "bind-mounted $SRC -> $DEST (fallback)"
        exit 0
    fi
    log "bind mount failed; leaving $DEST empty"
    exit 1
}

# How much RAM is free right now?
avail_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
case "$avail_kb" in ''|*[!0-9]*) avail_kb=0 ;; esac

if [ "$avail_kb" -lt "$MIN_KB" ]; then
    log "only ${avail_kb} kB available (< ${MIN_KB}); using bind mount"
    bind_fallback
fi

# Fast path: tmpfs + full copy. Any failure degrades to the bind mount.
if ! mount -t tmpfs -o "size=${TMPFS_SIZE},mode=0755" tmpfs "$DEST"; then
    log "tmpfs mount failed; using bind mount"
    bind_fallback
fi

if ! cp -a "$SRC/." "$DEST/" || [ ! -x "$DEST/hifi-qt" ]; then
    log "copy into tmpfs failed; using bind mount"
    bind_fallback
fi

log "staged $SRC in tmpfs at $DEST (${avail_kb} kB was available)"
exit 0
