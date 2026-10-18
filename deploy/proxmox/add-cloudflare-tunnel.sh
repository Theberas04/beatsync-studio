#!/usr/bin/env bash
# Zet een Cloudflare Tunnel op in de BeatSync-container, zodat de site op een
# hostname (https) bereikbaar wordt in plaats van alleen op het LAN-IP.
#
#   ./add-cloudflare-tunnel.sh 102            # token wordt gevraagd
#   CF_TUNNEL_TOKEN=... ./add-cloudflare-tunnel.sh 102
#
# De tunnel is "remotely managed": je maakt hem in het Cloudflare Zero Trust
# dashboard en plakt hier de token. Het publieke adres stel je daarna in het
# dashboard in op:  http://127.0.0.1:8080
set -euo pipefail

CTID="${1:-${CTID:-}}"
TOKEN="${CF_TUNNEL_TOKEN:-}"
SITE_DIR="/var/www/beatsync"

ok_()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Draai dit als root op de Proxmox-host."
[ -n "$CTID" ] || die "Gebruik: $0 <container-id>"
command -v pct >/dev/null || die "pct niet gevonden: dit is geen Proxmox VE-host."
pct status "$CTID" >/dev/null 2>&1 || die "Container $CTID bestaat niet."
[ "$(pct status "$CTID")" = "status: running" ] || die "Container $CTID draait niet."

# ----------------------------- token -------------------------------------
if [ -z "$TOKEN" ]; then
  cat >&2 <<'EOF'
Waar vind je de token?
  Cloudflare Zero Trust -> Networks -> Tunnels -> Create a tunnel
  -> Cloudflared -> naam kiezen -> de token op de installatiepagina kopiëren
    (het lange deel achter 'cloudflared service install ').

EOF
  printf 'Tunnel-token (wordt niet getoond): '
  read -rs TOKEN
  printf '\n'
fi
[ -n "$TOKEN" ] || die "Geen token opgegeven."
if [ "${#TOKEN}" -lt 40 ]; then
  warn "De token lijkt kort (${#TOKEN} tekens). Controleer of je het hele token hebt."
fi

# ----------------------------- nginx-origin ------------------------------
# De tunnel mag NOOIT naar poort 80 met een blinde https-redirect wijzen: dat
# geeft een lus. Daarom zetten we de config die beide gevallen aankan.
log "Origin-configuratie controleren…"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if pct exec "$CTID" -- test -f /etc/ssl/beatsync/cert.pem 2>/dev/null; then
  [ -f "$SCRIPT_DIR/nginx-beatsync.conf" ] || die "nginx-beatsync.conf niet gevonden naast dit script."
  pct push "$CTID" "$SCRIPT_DIR/nginx-beatsync.conf" /etc/nginx/sites-available/beatsync --perms 644
  log "Config geplaatst: poort 80 proxy-bewust, 443 met TLS, 8080 voor de tunnel."
else
  warn "Geen TLS-certificaat in de container; ik schrijf een HTTP-only config."
  pct exec "$CTID" -- bash -c 'cat > /etc/nginx/sites-available/beatsync' <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/beatsync;
    index index.html;
    charset utf-8;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Cache-Control "no-cache" always;

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}

server {
    listen 127.0.0.1:8080;
    server_name _;

    root /var/www/beatsync;
    index index.html;

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX
fi

pct exec "$CTID" -- rm -f /etc/nginx/sites-enabled/default
pct exec "$CTID" -- ln -sf /etc/nginx/sites-available/beatsync /etc/nginx/sites-enabled/beatsync
pct exec "$CTID" -- nginx -t || die "nginx -t faalde; configuratie niet geactiveerd."
pct exec "$CTID" -- systemctl reload nginx

log "Origin testen zoals Cloudflare hem ziet…"
code80="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' --max-time 5 http://127.0.0.1/ 2>/dev/null | tr -d '\r')"
code8080="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/ 2>/dev/null | tr -d '\r')"
if [ "$code80" = "200" ]; then
  ok_ "Poort 80 achter de proxy: 200 (geen redirect-lus)"
else
  warn "Poort 80 geeft '$code80' met X-Forwarded-Proto: https (verwacht 200)."
  warn "Zet de tunnel-dienst op HTTP 127.0.0.1:8080."
fi
if [ "$code8080" = "200" ]; then
  ok_ "Poort 8080 origin: 200"
else
  die "De 8080-origin antwoordt met '$code8080'. Controleer: pct exec $CTID -- nginx -t"
fi

# ----------------------------- cloudflared -------------------------------
if pct exec "$CTID" -- test -x /usr/bin/cloudflared 2>/dev/null; then
  log "cloudflared is al geïnstalleerd."
else
  log "cloudflared installeren (via de .deb van de officiële release)…"
  ARCH="$(pct exec "$CTID" -- dpkg --print-architecture | tr -d '\r')"
  case "$ARCH" in
    amd64) DEB_ARCH=amd64 ;;
    arm64) DEB_ARCH=arm64 ;;
    armhf) DEB_ARCH=arm ;;
    386|i386) DEB_ARCH=386 ;;
    *) die "Onbekende architectuur '$ARCH'; installeer cloudflared handmatig." ;;
  esac
  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${DEB_ARCH}.deb"
  log "  $URL"
  pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null"
  if ! pct exec "$CTID" -- bash -c "curl -fsSL --retry 3 --max-time 120 '${URL}' -o /tmp/cloudflared.deb"; then
    die "Downloaden van cloudflared mislukte. Heeft de container internet?"
  fi
  if ! pct exec "$CTID" -- bash -c 'dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1 || (export DEBIAN_FRONTEND=noninteractive; apt-get install -y -f -qq >/dev/null)'; then
    die "Installeren van cloudflared mislukte."
  fi
  pct exec "$CTID" -- rm -f /tmp/cloudflared.deb
  pct exec "$CTID" -- cloudflared --version || die "cloudflared niet uitvoerbaar na installatie."
fi

# ----------------------------- service -----------------------------------
log "Tunnel als systemd-service instellen…"
# Bestaande service eerst opruimen, zodat een nieuwe token echt wordt gebruikt.
pct exec "$CTID" -- bash -c 'if [ -f /etc/systemd/system/cloudflared.service ]; then cloudflared service uninstall >/dev/null 2>&1 || true; fi' || true
pct exec "$CTID" -- bash -c "cloudflared service install '${TOKEN}' >/dev/null 2>&1 || cloudflared service install '${TOKEN}'"
pct exec "$CTID" -- systemctl enable cloudflared >/dev/null 2>&1 || true
pct exec "$CTID" -- systemctl restart cloudflared

log "Controleren of de tunnel verbinding maakt…"
connected=0
for _ in $(seq 1 20); do
  if pct exec "$CTID" -- bash -c 'systemctl is-active --quiet cloudflared' 2>/dev/null; then
    if pct exec "$CTID" -- bash -c 'journalctl -u cloudflared --no-pager -n 60 2>/dev/null | grep -qiE "Registered tunnel connection|Connection.*registered"'; then
      connected=1; break
    fi
  fi
  sleep 3
done

if [ "$connected" -eq 1 ]; then
  log "Tunnel is verbonden met Cloudflare."
else
  warn "De service draait, maar ik zag nog geen 'Registered tunnel connection'."
  warn "Laatste logregels:"
  pct exec "$CTID" -- journalctl -u cloudflared --no-pager -n 15 2>/dev/null || true
fi

cat <<EOF

────────────────────────────────────────────────────────────
 Laatste stap: het publieke adres koppelen

 1. Cloudflare Zero Trust -> Networks -> Tunnels -> jouw tunnel
 2. Tab 'Public Hostname' -> Add a public hostname
      Subdomain : bijv. beatsync
      Domain    : jouw domein
      Service   : HTTP
      URL       : 127.0.0.1:8080
 3. Opslaan. Cloudflare maakt het DNS-record zelf aan.

 Daarna: https://beatsync.jouwdomein.nl
 (HTTPS van Cloudflare, dus de audiokoppeling werkt daar ook.)

 Beheer in de container:
   pct exec $CTID -- systemctl status cloudflared
   pct exec $CTID -- journalctl -u cloudflared -f
   pct exec $CTID -- cloudflared service uninstall   # tunnel stoppen

 Let op: een publieke hostname is voor iedereen bereikbaar die het adres kent.
 Wil je alleen toegang voor jezelf, zet dan Cloudflare Access voor de hostname.
────────────────────────────────────────────────────────────
EOF
