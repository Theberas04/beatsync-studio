#!/usr/bin/env bash
# Werkt de site in de container bij met de nieuwste index.html uit de GitHub-repo.
# Geen bestanden nodig: haalt de pagina zelf op en zet hem in de container.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/update-from-github.sh) 102
set -euo pipefail

CTID="${1:-${CTID:-}}"
SITE_DIR="/var/www/beatsync"
RAW="https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/index.html"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*"; }
log()  { printf '     %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { bad "Draai dit als root op de Proxmox-host."; exit 1; }
command -v pct >/dev/null || { bad "pct niet gevonden: dit is geen Proxmox VE-host."; exit 1; }
[ -n "$CTID" ] || { bad "Gebruik: $0 <container-id>"; exit 1; }
pct status "$CTID" >/dev/null 2>&1 || { bad "Container $CTID bestaat niet."; exit 1; }
[ "$(pct status "$CTID")" = "status: running" ] || { bad "Container $CTID draait niet. pct start $CTID"; exit 1; }

log "Nieuwste versie ophalen…"
if ! curl -fsSL --max-time 30 "$RAW" -o "$TMP"; then
  bad "Kon $RAW niet ophalen."
  exit 1
fi
NEW_SIZE="$(wc -c <"$TMP")"
if ! grep -q '<title>BeatSync' "$TMP"; then
  bad "Het opgehaalde bestand is geen BeatSync-pagina ($NEW_SIZE bytes). Niets gewijzigd."
  exit 1
fi
ok "Opgehaald: $NEW_SIZE bytes, sha256 $(sha256sum "$TMP" | cut -c1-16)…"

OLD_SIZE="$(pct exec "$CTID" -- bash -c "stat -c %s '$SITE_DIR/index.html' 2>/dev/null || echo 0" | tr -d '\r')"
log "In de container nu: ${OLD_SIZE:-0} bytes"

if [ "${OLD_SIZE:-0}" = "$NEW_SIZE" ] && pct exec "$CTID" -- bash -c "sha256sum '$SITE_DIR/index.html'" 2>/dev/null | grep -q "$(sha256sum "$TMP" | cut -d' ' -f1)"; then
  ok "De container heeft deze versie al. Niets te doen."
  exit 0
fi

pct exec "$CTID" -- bash -c "cp -a '$SITE_DIR/index.html' '$SITE_DIR/index.html.bak' 2>/dev/null || true"
pct exec "$CTID" -- bash -c "cat > '$SITE_DIR/index.html'" < "$TMP"

CHECK="$(pct exec "$CTID" -- bash -c "stat -c %s '$SITE_DIR/index.html'" | tr -d '\r')"
if [ "$CHECK" != "$NEW_SIZE" ]; then
  bad "Grootte in de container is $CHECK, verwacht $NEW_SIZE. Zet de backup terug met:"
  log "pct exec $CTID -- cp -a $SITE_DIR/index.html.bak $SITE_DIR/index.html"
  exit 1
fi
ok "Bijgewerkt naar $CHECK bytes."

if pct exec "$CTID" -- bash -c "command -v nginx >/dev/null"; then
  pct exec "$CTID" -- systemctl reload nginx 2>/dev/null || true
fi
ok "Klaar. Ververs de pagina in je browser (Ctrl+F5)."
