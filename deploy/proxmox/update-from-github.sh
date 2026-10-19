#!/usr/bin/env bash
# Werkt de site in de container bij met de nieuwste index.html én de mediabestanden
# uit de GitHub-repo. Geen bestanden nodig: alles wordt zelf opgehaald.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/update-from-github.sh) 103
#   (103 = het container-ID; laat weg om CTID uit de omgeving te gebruiken)
set -euo pipefail

CTID="${1:-${CTID:-}}"
SITE_DIR="/var/www/beatsync"
REPO="Theberas04/beatsync-studio"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
# Cache-buster: raw.githubusercontent serveert anders tot ~5 min een oude versie.
CB="cb=$(date +%s)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
log()  { printf '     %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { bad "Draai dit als root op de Proxmox-host."; exit 1; }
command -v pct >/dev/null || { bad "pct niet gevonden: dit is geen Proxmox VE-host."; exit 1; }
[ -n "$CTID" ] || { bad "Gebruik: $0 <container-id>"; exit 1; }
pct status "$CTID" >/dev/null 2>&1 || { bad "Container $CTID bestaat niet."; exit 1; }
[ "$(pct status "$CTID")" = "status: running" ] || { bad "Container $CTID draait niet. pct start $CTID"; exit 1; }

# ---------------------------------------------------------------- index.html
log "Nieuwste index.html ophalen…"
if ! curl -fsSL --max-time 30 "$RAW_BASE/index.html?$CB" -o "$TMP"; then
  bad "Kon $RAW_BASE/index.html niet ophalen."
  exit 1
fi
NEW_SIZE="$(wc -c <"$TMP")"
if ! grep -q '<title>BeatSync' "$TMP"; then
  bad "Het opgehaalde bestand is geen BeatSync-pagina ($NEW_SIZE bytes). Niets gewijzigd."
  exit 1
fi
NEW_SHA="$(sha256sum "$TMP" | cut -d' ' -f1)"
ok "Opgehaald: $NEW_SIZE bytes, sha256 $(printf '%s' "$NEW_SHA" | cut -c1-16)…"

PAGE_CHANGED=1
if pct exec "$CTID" -- bash -c "sha256sum '$SITE_DIR/index.html' 2>/dev/null" | grep -q "$NEW_SHA"; then
  PAGE_CHANGED=0
  ok "index.html in de container is al deze versie."
else
  OLD_SIZE="$(pct exec "$CTID" -- bash -c "stat -c %s '$SITE_DIR/index.html' 2>/dev/null || echo 0" | tr -d '\r')"
  log "In de container nu: ${OLD_SIZE:-0} bytes"
  pct exec "$CTID" -- bash -c "cp -a '$SITE_DIR/index.html' '$SITE_DIR/index.html.bak' 2>/dev/null || true"
  pct exec "$CTID" -- bash -c "cat > '$SITE_DIR/index.html'" < "$TMP"
  CHECK="$(pct exec "$CTID" -- bash -c "stat -c %s '$SITE_DIR/index.html'" | tr -d '\r')"
  if [ "$CHECK" != "$NEW_SIZE" ]; then
    bad "Grootte in de container is $CHECK, verwacht $NEW_SIZE. Zet de backup terug met:"
    log "pct exec $CTID -- cp -a $SITE_DIR/index.html.bak $SITE_DIR/index.html"
    exit 1
  fi
  ok "index.html bijgewerkt naar $CHECK bytes."
fi

# ------------------------------------------------------------------- media
echo
log "Mediabestanden synchroniseren…"
MEDIA_LIST=""
if command -v python3 >/dev/null 2>&1; then
  MEDIA_LIST="$(curl -fsSL --max-time 25 "https://api.github.com/repos/${REPO}/contents/media?ref=main" 2>/dev/null \
    | python3 -c 'import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(data, list):
    for item in data:
        if isinstance(item, dict) and item.get("type") == "file":
            print(item["name"])' 2>/dev/null || true)"
fi
if [ -z "$MEDIA_LIST" ]; then
  warn "Geen lijst via de GitHub-API (limiet of geen python3); ik gebruik de vaste lijst."
  MEDIA_LIST="nep-beatclip.mp4"
fi

pct exec "$CTID" -- bash -c "mkdir -p '$SITE_DIR/media'"
MEDIA_FAIL=0
for name in $MEDIA_LIST; do
  case "$name" in */*|.*) warn "Onverwachte naam overgeslagen: $name"; continue ;; esac
  MT="$(mktemp)"
  if ! curl -fsSL --max-time 180 "$RAW_BASE/media/$name?$CB" -o "$MT"; then
    bad "Kon media/$name niet ophalen."
    MEDIA_FAIL=1
    rm -f "$MT"
    continue
  fi
  MSIZE="$(wc -c <"$MT")"
  MSHA="$(sha256sum "$MT" | cut -d' ' -f1)"
  if pct exec "$CTID" -- bash -c "sha256sum '$SITE_DIR/media/$name' 2>/dev/null" | grep -q "$MSHA"; then
    ok "media/$name staat er al ($MSIZE bytes)."
  else
    pct exec "$CTID" -- bash -c "cat > '$SITE_DIR/media/$name'" < "$MT"
    PUSHED="$(pct exec "$CTID" -- bash -c "stat -c %s '$SITE_DIR/media/$name'" | tr -d '\r')"
    if [ "$PUSHED" = "$MSIZE" ]; then
      ok "media/$name geplaatst ($MSIZE bytes)."
    else
      bad "media/$name is $PUSHED bytes in de container, verwacht $MSIZE."
      MEDIA_FAIL=1
    fi
  fi
  rm -f "$MT"
done

# --------------------------------------------------------------- afronden
TELLER="$(pct exec "$CTID" -- bash -c "ls -1 '$SITE_DIR/media' 2>/dev/null | wc -l" | tr -d '\r')"
log "Bestanden in $SITE_DIR/media: ${TELLER:-0}"

if pct exec "$CTID" -- bash -c "command -v nginx >/dev/null"; then
  pct exec "$CTID" -- systemctl reload nginx 2>/dev/null || true
fi

echo
if [ "$MEDIA_FAIL" -eq 0 ] && [ "$PAGE_CHANGED" -eq 0 ]; then
  ok "Alles stond al bij. Niets te doen."
elif [ "$MEDIA_FAIL" -eq 0 ]; then
  ok "Klaar. Ververs de pagina in je browser (Ctrl+F5)."
else
  warn "De pagina staat er, maar niet alle mediabestanden. Zie de meldingen hierboven."
  exit 1
fi
