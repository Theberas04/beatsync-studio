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

# Headers opvragen zonder curl in de container (bash /dev/tcp werkt altijd).
probe_head() {   # $1=poort  $2=pad
  printf '%s\n' \
    'exec 3<>/dev/tcp/127.0.0.1/"$1" || exit 9' \
    'printf "GET %s HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\n\\r\\n" "$2" >&3' \
    'timeout 5 head -20 <&3' \
    | pct exec "$CTID" -- bash -s "$1" "${2:-/}" 2>/dev/null
}

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
MEDIA_LIST_OK=0
if command -v python3 >/dev/null 2>&1; then
  MEDIA_JSON="$(curl -sSL --max-time 25 "https://api.github.com/repos/${REPO}/contents/media?ref=main" 2>/dev/null || true)"
  if [ -n "$MEDIA_JSON" ]; then
    MEDIA_LIST="$(printf '%s' "$MEDIA_JSON" | python3 -c 'import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if not isinstance(data, list):
    raise SystemExit(1)
for item in data:
    name = item.get("name", "") if isinstance(item, dict) else ""
    if isinstance(item, dict) and item.get("type") == "file" and name and not name.startswith("."):
        print(name)' 2>/dev/null)"
    if [ $? -eq 0 ]; then MEDIA_LIST_OK=1; fi
  fi
fi
if [ "$MEDIA_LIST_OK" -ne 1 ]; then
  warn "Geen betrouwbare medialijst van GitHub (limiet of netwerk); mediabestanden overgeslagen."
fi

pct exec "$CTID" -- bash -c "mkdir -p '$SITE_DIR/media'"
MEDIA_FAIL=0
if [ "$MEDIA_LIST_OK" -eq 1 ]; then
  for name in $MEDIA_LIST; do
    case "$name" in */*|.*) warn "Onverwachte naam overgeslagen: $name"; continue ;; esac
    MT="$(mktemp)"
    if ! curl -fsSL --max-time 180 "${RAW_BASE}/media/${name}?${CB}" -o "$MT"; then
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

  # bestanden die niet meer in de repo staan, horen ook niet meer in de container
  EXISTING="$(pct exec "$CTID" -- bash -c "ls -1 '$SITE_DIR/media' 2>/dev/null" | tr -d '\r')"
  for f in $EXISTING; do
    case "$f" in .*|"") continue ;; esac
    case " $MEDIA_LIST " in
      *" $f "*) ;;
      *)
        if pct exec "$CTID" -- rm -f "$SITE_DIR/media/$f"; then
          ok "media/$f verwijderd (staat niet meer in de repo)."
        else
          warn "Kon media/$f niet verwijderen."
        fi
        ;;
    esac
  done
  if [ -z "$MEDIA_LIST" ]; then ok "Geen mediabestanden in de repo; alleen index.html bijgewerkt."; fi
else
  log "media-synchronisatie overgeslagen."
fi

# --------------------------------------------------------------- afronden
# Controleer of nginx de bestanden ook echt als video serveert.
if pct exec "$CTID" -- bash -c "command -v nginx >/dev/null"; then
  for name in $MEDIA_LIST; do
    case "$name" in */*|.*) continue ;; esac
    HEAD="$(probe_head 8080 "/media/$name")"
    STATUS="$(printf '%s' "$HEAD" | head -1 | tr -d '\r' | awk '{print $2}')"
    TYPE="$(printf '%s' "$HEAD" | tr -d '\r' | awk 'tolower($1)=="content-type:"{print $2; exit}')"
    case "$STATUS:$TYPE" in
      200:video/*) ok "web: /media/$name -> 200 $TYPE" ;;
      200:text/html*)
        bad "web: /media/$name geeft de HTML-pagina terug in plaats van de video."
        log "Oorzaak: nginx valt terug op index.html; de media-locatie ontbreekt in de config."
        log "Oplossing: ./fix-loop.sh $CTID   (schrijft de config met een /media/-blok)"
        MEDIA_FAIL=1 ;;
      404:*) bad "web: /media/$name -> 404 (bestand staat niet in $SITE_DIR/media)."; MEDIA_FAIL=1 ;;
      200:*) warn "web: /media/$name -> 200 met type ${TYPE:-onbekend} (geen video)." ;;
      *)     warn "web: /media/$name -> ${STATUS:-geen antwoord}." ;;
    esac
  done
fi

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
