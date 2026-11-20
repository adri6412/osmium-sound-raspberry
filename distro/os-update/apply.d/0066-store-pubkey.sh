# shellcheck shell=sh
# 0066 — fa funzionare lo store dei VU meter (e delle animazioni) sul Pi.
#
# PERCHÉ
# Lo store scarica il suo catalogo da file.osmiumsound.it/{vu,anim}/ e ne
# verifica la firma Ed25519. Di default (api_server.py) la verifica usa
# /etc/hifi-player/ota-pubkey.pem: giusto sull'immagine x86, dove quella chiave
# firma anche il catalogo. Questo fork ha una SUA chiave OTA (firma i bundle
# RAUC del Pi), che NON corrisponde alla firma del catalogo: così lo store
# rifiutava ogni catalogo e non mostrava nessuna skin da scaricare.
#
# COSA FA
# Installa la chiave pubblica upstream (x86) che firma il catalogo in
# /etc/hifi-player/store-pubkey.pem e un drop-in di hifi-api che punta lì le due
# variabili HIFI_VU_STORE_PUBKEY / HIFI_ANIM_STORE_PUBKEY. La chiave OTA del fork
# resta intatta. È tutta roba pubblica: fidarsi di questa chiave permette solo di
# accettare lo stesso catalogo/pacchetti che accetta l'immagine x86.
#
# Idempotente: ensure_file_content scrive solo se il contenuto cambia; il
# daemon-reload + restart di hifi-api partono solo se qualcosa è cambiato.

mkdir -p /etc/hifi-player /etc/systemd/system/hifi-api.service.d

ensure_file_content /etc/hifi-player/store-pubkey.pem 0644 <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAQ2PMjMQU+ReBzEHMfcyTCdpbX7TQndgGkUY2XLyd4Xk=
-----END PUBLIC KEY-----
EOF

ensure_file_content /etc/systemd/system/hifi-api.service.d/10-store-pubkey.conf 0644 <<'EOF'
# Osmium Sound (Raspberry Pi fork) — trust anchor for the VU-meter and
# animation stores. The stores verify their catalogue signature; the fork OTA
# key does not match it, so point the check at the upstream (x86) catalogue
# key shipped at /etc/hifi-player/store-pubkey.pem. See apply.d/0066.
[Service]
Environment=HIFI_VU_STORE_PUBKEY=/etc/hifi-player/store-pubkey.pem
Environment=HIFI_ANIM_STORE_PUBKEY=/etc/hifi-player/store-pubkey.pem
EOF

if migration_changed && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart hifi-api.service 2>/dev/null || true
    log_info "store trust key installed; hifi-api reloaded"
fi
