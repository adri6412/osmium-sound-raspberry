#!/bin/bash
# Osmium Sound — the single renderer that injects the chosen I2S HAT overlay into
# a boot config.txt (hifi-rpi-dacoverlay.sh).
#
# This one script is the whole persistence story for the DAC/HAT feature: it runs
# at runtime (from /set_dac_hat) AND on every OTA re-generation of the boot FAT
# (from hifi-rpi-bootfat.sh). If it is not idempotent, every update would stack a
# second managed block; if it does not clear on empty, "No HAT" would never undo a
# previous choice. Both are exercised here against a throwaway config.txt.
set -u

REND="distro/config/includes.chroot/usr/local/sbin/hifi-rpi-dacoverlay.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dacoverlay.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CFG="$WORK/config.txt"

# A config.txt that already carries the managed markers, as the shipped template
# does. The body between them is stale on purpose — the renderer must replace it.
fresh_cfg() {
    cat > "$CFG" <<'EOF'
dtparam=audio=off
[all]
# >>> osmium-dac
# I2S HAT overlay — managed by hifi-rpi-dacoverlay.sh, do NOT edit by hand.
dtoverlay=stale-leftover
# <<< osmium-dac
EOF
}

count() { grep -cx "$1" "$CFG"; }

# ── a real overlay with params lands as a single dtoverlay line ──────
fresh_cfg
sh "$REND" "$CFG" "allo-boss-dac-pcm512x-audio,slave" >/dev/null 2>&1
if grep -qx 'dtoverlay=allo-boss-dac-pcm512x-audio,slave' "$CFG"; then ok; else
    bad "overlay con params non scritto"; fi
if ! grep -qx 'dtoverlay=stale-leftover' "$CFG"; then ok; else
    bad "il vecchio dtoverlay non è stato rimosso"; fi
# dtparam=audio=off is left untouched (I2S HATs want the onboard audio off).
if grep -qx 'dtparam=audio=off' "$CFG"; then ok; else
    bad "dtparam=audio=off perso"; fi

# ── idempotence: a second render replaces, never stacks ──────────────
sh "$REND" "$CFG" "hifiberry-dacplus" >/dev/null 2>&1
if [ "$(count '# >>> osmium-dac')" = 1 ] && [ "$(count '# <<< osmium-dac')" = 1 ]; then ok; else
    bad "doppio blocco: marker duplicati dopo una seconda applicazione"; fi
if [ "$(count 'dtoverlay=hifiberry-dacplus')" = 1 ] \
   && ! grep -qx 'dtoverlay=allo-boss-dac-pcm512x-audio,slave' "$CFG"; then ok; else
    bad "il secondo overlay non ha sostituito il primo"; fi

# ── empty value = No HAT: block kept, no dtoverlay line ──────────────
sh "$REND" "$CFG" "" >/dev/null 2>&1
if [ "$(count '# >>> osmium-dac')" = 1 ] && ! grep -q '^dtoverlay=' "$CFG"; then ok; else
    bad "scelta vuota non ha pulito il dtoverlay"; fi

# ── missing markers (old config.txt): block is appended once ─────────
printf 'dtparam=audio=off\n[all]\n' > "$CFG"
sh "$REND" "$CFG" "iqaudio-dacplus" >/dev/null 2>&1
if [ "$(count '# >>> osmium-dac')" = 1 ] \
   && grep -qx 'dtoverlay=iqaudio-dacplus' "$CFG"; then ok; else
    bad "blocco non appeso quando i marker mancano"; fi

# ── a dtoverlay= prefix is tolerated, not doubled ────────────────────
fresh_cfg
sh "$REND" "$CFG" "dtoverlay=hifiberry-digi" >/dev/null 2>&1
if grep -qx 'dtoverlay=hifiberry-digi' "$CFG" \
   && ! grep -q 'dtoverlay=dtoverlay=' "$CFG"; then ok; else
    bad "prefisso dtoverlay= non gestito"; fi

# ── a value with shell metacharacters is rejected, file untouched ────
fresh_cfg
before="$(cat "$CFG")"
if sh "$REND" "$CFG" 'evil; reboot' >/dev/null 2>&1; then
    bad "valore con metacaratteri accettato"; else ok; fi
if [ "$(cat "$CFG")" = "$before" ]; then ok; else
    bad "config.txt modificato nonostante il valore invalido"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
