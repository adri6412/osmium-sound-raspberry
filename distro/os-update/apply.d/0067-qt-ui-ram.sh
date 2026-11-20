# shellcheck shell=sh
# 0067 — carica in RAM l'interfaccia Qt su schermo, per i device già in campo.
#
# PERCHÉ
# Il rootfs è squashfs compresso read-only: la UI Qt legge QML e ~23 MB di asset
# a richiesta, pagando una fault+decompressione al primo accesso a ogni schermata
# → scatti sui cambi schermo. Copiare /opt/hifi-qt in una tmpfs una volta al boot
# li decomprime tutti in sequenza e rende gli accessi successivi letture da RAM.
#
# COSA FA
# Installa il servizio oneshot hifi-qt-ram.service (+ lo script) che prepara
# /run/hifi-qt (tmpfs con copia, o bind-mount di /opt/hifi-qt come fallback a RAM
# bassa / in caso di errore) e un drop-in che fa partire hifi-qt da lì. Il nuovo
# percorso vale al prossimo riavvio della UI (o del box).
#
# Idempotente: ensure_file_content scrive solo se cambia; daemon-reload solo se
# qualcosa è cambiato. Non riavvia la UI qui (eviterebbe uno sfarfallio a ogni
# update): il cambio ha effetto al riavvio.

mkdir -p /usr/local/sbin /etc/systemd/system/hifi-qt.service.d

ensure_file_content /usr/local/sbin/hifi-qt-ram.sh 0755 <<'EOF'
#!/bin/sh
# Osmium Sound (Raspberry Pi fork) — stage the Qt on-screen UI payload in RAM.
# /run/hifi-qt is always made a valid mount of the payload: tmpfs + copy when
# there is RAM to spare, else a bind mount of /opt/hifi-qt (never slower than the
# squashfs). hifi-qt.service runs from /run/hifi-qt. Idempotent. See apply.d/0067.
set -eu

SRC=/opt/hifi-qt
DEST=/run/hifi-qt
MIN_KB=768000
TMPFS_SIZE=256m

log() { printf 'hifi-qt-ram: %s\n' "$*" >&2; }

if mountpoint -q "$DEST" 2>/dev/null; then
    log "already mounted at $DEST"
    exit 0
fi

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

avail_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
case "$avail_kb" in ''|*[!0-9]*) avail_kb=0 ;; esac

if [ "$avail_kb" -lt "$MIN_KB" ]; then
    log "only ${avail_kb} kB available (< ${MIN_KB}); using bind mount"
    bind_fallback
fi

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
EOF

ensure_file_content /etc/systemd/system/hifi-qt-ram.service 0644 <<'EOF'
[Unit]
Description=Osmium Sound — stage the Qt on-screen UI payload in RAM
DefaultDependencies=no
After=local-fs.target
Before=hifi-qt.service
ConditionPathExists=/opt/hifi-qt/hifi-qt

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/hifi-qt-ram.sh
ExecStop=/bin/sh -c 'umount /run/hifi-qt 2>/dev/null || true'

[Install]
WantedBy=hifi-qt.service
EOF

ensure_file_content /etc/systemd/system/hifi-qt.service.d/10-ram.conf 0644 <<'EOF'
# Osmium Sound (Raspberry Pi fork) — run the Qt kiosk from its RAM-staged copy.
# hifi-qt-ram.service populates /run/hifi-qt first. See apply.d/0067.
[Unit]
Requires=hifi-qt-ram.service
After=hifi-qt-ram.service

[Service]
WorkingDirectory=/run/hifi-qt
ExecStart=
ExecStart=/run/hifi-qt/hifi-qt --assets /run/hifi-qt/assets --locales /run/hifi-qt/locales
EOF

if migration_changed && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    log_info "Qt UI RAM staging installed; active at next UI restart"
fi
