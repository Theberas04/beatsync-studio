#!/usr/bin/env bash
# Lost de redirect-lus op die ontstaat als een Cloudflare Tunnel naar poort 80
# van de container wijst: nginx stuurde daar blind door naar https, Cloudflare
# levert weer af op poort 80, enzovoort.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/fix-loop.sh) 102
#
# Zelfstandig: heeft geen andere bestanden uit de repo nodig.
set -uo pipefail

CTID="${1:-${CTID:-102}}"
SITE=/etc/nginx/sites-available/beatsync

ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
log()  { printf '     %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { bad "Draai dit als root op de Proxmox-host."; exit 1; }
command -v pct >/dev/null || { bad "pct niet gevonden: dit is geen Proxmox VE-host."; exit 1; }
pct status "$CTID" >/dev/null 2>&1 || { bad "Container $CTID bestaat niet."; exit 1; }
[ "$(pct status "$CTID")" = "status: running" ] || { bad "Container $CTID draait niet. pct start $CTID"; exit 1; }

echo "== Situatie voor de fix =="
CODE_BEFORE="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' --max-time 5 http://127.0.0.1/ 2>/dev/null | tr -d '\r')"
log "poort 80 met X-Forwarded-Proto: https -> ${CODE_BEFORE:-geen antwoord}"
[ "$CODE_BEFORE" = "301" ] || [ "$CODE_BEFORE" = "302" ] && warn "Dat is de lus: 301 naar https terwijl Cloudflare al TLS deed."

if pct exec "$CTID" -- test -s "$SITE" 2>/dev/null; then
  BACKUP="$SITE.bak-$(date +%Y%m%d-%H%M%S)"
  pct exec "$CTID" -- cp -a "$SITE" "$BACKUP"
  log "Backup gemaakt: $BACKUP"
fi

echo "== Configuratie schrijven =="
if pct exec "$CTID" -- test -f /etc/ssl/beatsync/cert.pem 2>/dev/null; then
  log "Certificaat gevonden; HTTPS-blok wordt meegenomen."
  pct exec "$CTID" -- bash -c "cat > $SITE" <<'NGINX'
# BeatSync Studio — nginx site (proxy-bewust)

# Door Cloudflare? Dan is TLS al gedaan en mag poort 80 gewoon serveren.
map $http_cf_ray $beatsync_from_cf {
    default   0;
    "~."      1;
}
map "$http_cf_visitor|$http_x_forwarded_proto" $beatsync_upstream_https {
    default   0;
    "~*https" 1;
}
map "$beatsync_from_cf$beatsync_upstream_https" $beatsync_serve_plain {
    default   0;
    "~1"      1;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    root /var/www/beatsync;
    index index.html;
    charset utf-8;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Cache-Control "no-cache" always;

    location / {
        if ($beatsync_serve_plain = 0) {
            return 301 https://$host$request_uri;
        }
        try_files $uri $uri/ /index.html;
    }

    access_log /var/log/nginx/beatsync.access.log;
    error_log  /var/log/nginx/beatsync.error.log warn;
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;

    root /var/www/beatsync;
    index index.html;
    charset utf-8;

    ssl_certificate     /etc/ssl/beatsync/cert.pem;
    ssl_certificate_key /etc/ssl/beatsync/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:5m;
    ssl_session_timeout 10m;

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
else
  log "Geen certificaat; HTTP-only config (poort 80 + 8080)."
  pct exec "$CTID" -- bash -c "cat > $SITE" <<'NGINX'
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
pct exec "$CTID" -- ln -sf "$SITE" /etc/nginx/sites-enabled/beatsync
if ! pct exec "$CTID" -- nginx -t; then
  bad "nginx -t faalde; de oude configuratie blijft actief."
  log "Zet de backup terug: pct exec $CTID -- cp -a $SITE.bak-* $SITE"
  exit 1
fi
pct exec "$CTID" -- systemctl reload nginx || { bad "Herladen van nginx faalde."; exit 1; }

echo "== Situatie na de fix =="
CODE_PROXY="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' --max-time 5 http://127.0.0.1/ 2>/dev/null | tr -d '\r')"
CODE_CFRAY="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' -H 'CF-Ray: test' --max-time 5 http://127.0.0.1/ 2>/dev/null | tr -d '\r')"
CODE_LAN="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/ 2>/dev/null | tr -d '\r')"
CODE_8080="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/ 2>/dev/null | tr -d '\r')"
TITLE="$(pct exec "$CTID" -- curl -s --max-time 5 -H 'X-Forwarded-Proto: https' http://127.0.0.1/ 2>/dev/null | grep -o '<title>[^<]*</title>' | head -1)"

log "via proxy (X-Forwarded-Proto): $CODE_PROXY"
log "via proxy (CF-Ray):            $CODE_CFRAY"
log "zonder proxy-headers:          $CODE_LAN  (301 = netjes naar https)"
log "poort 8080:                    $CODE_8080"
[ -n "$TITLE" ] && log "pagina: $TITLE"

FAIL=0
[ "$CODE_PROXY" = "200" ] || { bad "Proxy-verzoek geeft $CODE_PROXY (verwacht 200)."; FAIL=1; }
[ "$CODE_CFRAY" = "200" ] || { bad "Verzoek met CF-Ray geeft $CODE_CFRAY (verwacht 200)."; FAIL=1; }
[ "$CODE_8080" = "200" ]  || { bad "Poort 8080 geeft $CODE_8080 (verwacht 200)."; FAIL=1; }

if [ "$FAIL" -eq 0 ]; then
  ok "De lus is weg: Cloudflare-verkeer wordt nu gewoon geserveerd."
  log "Test publiek: https://<jouw-hostname>/ — dashboard-dienst: HTTP 127.0.0.1:8080"
else
  bad "Er blijven punten over; zie hierboven."
fi
exit "$FAIL"
