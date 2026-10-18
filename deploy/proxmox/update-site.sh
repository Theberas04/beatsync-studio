#!/usr/bin/env bash
# Werkt de website in een bestaande BeatSync-container bij met een nieuwe index.html.
# Uitvoeren op de Proxmox-host als root, met de nieuwe index.html ernaast:
#   ./update-site.sh 105            (105 = container-ID)
set -euo pipefail

CTID="${1:-${CTID:-}}"
SITE_DIR="/var/www/beatsync"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Draai dit script als root op de Proxmox-host." >&2; exit 1; }
[ -n "$CTID" ] || { echo "Gebruik: $0 <container-id>" >&2; exit 1; }
[ -f "$SCRIPT_DIR/index.html" ] || { echo "index.html ontbreekt naast dit script." >&2; exit 1; }
pct status "$CTID" >/dev/null 2>&1 || { echo "Container $CTID bestaat niet." >&2; exit 1; }

if [ "$(pct status "$CTID")" != "status: running" ]; then
  echo "Container $CTID starten…"
  pct start "$CTID"
  sleep 3
fi

echo "Nieuwe index.html kopiëren naar container $CTID…"
pct push "$CTID" "$SCRIPT_DIR/index.html" "$SITE_DIR/index.html" --perms 644
pct exec "$CTID" -- nginx -t
pct exec "$CTID" -- systemctl reload nginx

if [ -f "$SCRIPT_DIR/nginx-beatsync.conf" ]; then
  echo "nginx-configuratie ook bijwerken…"
  pct push "$CTID" "$SCRIPT_DIR/nginx-beatsync.conf" /etc/nginx/sites-available/beatsync --perms 644
  pct exec "$CTID" -- nginx -t && pct exec "$CTID" -- systemctl reload nginx
fi

echo "Bijgewerkt. Ververs de pagina in je browser (Ctrl+F5)."
