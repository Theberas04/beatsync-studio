#!/usr/bin/env bash
# Lost de redirect-lus op die ontstaat als een Cloudflare Tunnel naar poort 80
# van de container wijst: nginx stuurde daar blind door naar https, Cloudflare
# levert weer af op poort 80, enzovoort.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/fix-loop.sh) 102
#   ... [hostname]   # optioneel: test daarna ook https://<hostname>/ van buitenaf
#
# Zelfstandig: heeft geen andere bestanden uit de repo nodig.
set -uo pipefail

CTID="${1:-${CTID:-102}}"
SITE=/etc/nginx/sites-available/beatsync

ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
log()  { printf '     %s\n' "$*"; }
# Status/body opvragen zonder curl in de container (bash /dev/tcp werkt altijd).
probe_status() {   # $1=poort  $2=pad  $3=header (optioneel)
  printf '%s\n' \
    'exec 3<>/dev/tcp/127.0.0.1/"$1" || exit 9' \
    'printf "GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n" "$2" >&3' \
    '[ -n "$3" ] && printf "%s\r\n" "$3" >&3' \
    'printf "\r\n" >&3' \
    'IFS=" " read -r -t 5 _ code _ <&3' \
    'printf "%s" "$code"' \
    | pct exec "$CTID" -- bash -s "$1" "${2:-/}" "${3:-}" 2>/dev/null | tr -cd '0-9'
}
probe_body() {     # $1=poort  $2=pad
  printf '%s\n' \
    'exec 3<>/dev/tcp/127.0.0.1/"$1" || exit 9' \
    'printf "GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n" "$2" >&3' \
    'printf "\r\n" >&3' \
    'timeout 5 cat <&3' \
    | pct exec "$CTID" -- bash -s "$1" "${2:-/}" 2>/dev/null
}

[ "$(id -u)" -eq 0 ] || { bad "Draai dit als root op de Proxmox-host."; exit 1; }
command -v pct >/dev/null || { bad "pct niet gevonden: dit is geen Proxmox VE-host."; exit 1; }
pct status "$CTID" >/dev/null 2>&1 || { bad "Container $CTID bestaat niet."; exit 1; }
[ "$(pct status "$CTID")" = "status: running" ] || { bad "Container $CTID draait niet. pct start $CTID"; exit 1; }

echo "== Situatie voor de fix =="
CODE_BEFORE="$(probe_status 80 / "X-Forwarded-Proto: https")"
log "poort 80 met X-Forwarded-Proto: https -> ${CODE_BEFORE:-geen antwoord}"
if [ "$CODE_BEFORE" = "301" ] || [ "$CODE_BEFORE" = "302" ]; then
  warn "Dat is de lus: 301 naar https terwijl Cloudflare al TLS deed."
fi

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

    # Mediabestanden: nooit terugvallen op index.html (anders krijgt de browser
    # een HTML-pagina waar hij een video verwacht).
    location /media/ {
        try_files $uri =404;
    }

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

    # Mediabestanden: nooit terugvallen op index.html (anders krijgt de browser
    # een HTML-pagina waar hij een video verwacht).
    location /media/ {
        try_files $uri =404;
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

    # Mediabestanden: nooit terugvallen op index.html (anders krijgt de browser
    # een HTML-pagina waar hij een video verwacht).
    location /media/ {
        try_files $uri =404;
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

    # Mediabestanden: nooit terugvallen op index.html (anders krijgt de browser
    # een HTML-pagina waar hij een video verwacht).
    location /media/ {
        try_files $uri =404;
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

    # Mediabestanden: nooit terugvallen op index.html (anders krijgt de browser
    # een HTML-pagina waar hij een video verwacht).
    location /media/ {
        try_files $uri =404;
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
CODE_PROXY="$(probe_status 80 / "X-Forwarded-Proto: https")"
CODE_CFRAY="$(probe_status 80 / "CF-Ray: 0123456789abcdef-AMS")"
CODE_LAN="$(probe_status 80 /)"
CODE_8080="$(probe_status 8080 /)"
CODE_HEALTH="$(probe_status 8080 /healthz)"

log "via proxy (X-Forwarded-Proto): ${CODE_PROXY:-geen antwoord}"
log "via proxy (CF-Ray):            ${CODE_CFRAY:-geen antwoord}"
log "zonder proxy-headers:          ${CODE_LAN:-geen antwoord}  (301 = netjes naar https)"
log "poort 8080:                    ${CODE_8080:-geen antwoord}"
log "8080 /healthz:                 ${CODE_HEALTH:-geen antwoord}"

FAIL=0
if [ -z "$CODE_PROXY$CODE_CFRAY$CODE_8080" ]; then
  bad "Geen enkel antwoord gemeten; bash zonder /dev/tcp of nginx luistert niet."
  log "Controleer: pct exec $CTID -- ss -lntp | grep -E ':80|:8080'"
fi
[ "$CODE_PROXY" = "200" ] || { bad "Proxy-verzoek geeft $CODE_PROXY (verwacht 200)."; FAIL=1; }
[ "$CODE_CFRAY" = "200" ] || { bad "Verzoek met CF-Ray geeft $CODE_CFRAY (verwacht 200)."; FAIL=1; }
[ "$CODE_8080" = "200" ]  || { bad "Poort 8080 geeft $CODE_8080 (verwacht 200)."; FAIL=1; }

if [ -n "${2:-}" ] && command -v curl >/dev/null 2>&1; then
  PUB="$(curl -s -o /tmp/beatsync-pub.html -D /tmp/beatsync-pub.hdr -w '%{http_code}' --max-redirs 0 --max-time 20 "https://$2/" 2>/dev/null)"
  log "publiek https://$2/ -> ${PUB:-geen antwoord}"
  if [ "$PUB" = "200" ]; then
    ok "Publiek bereikbaar."
    TITLE="$(grep -o '<title>[^<]*</title>' /tmp/beatsync-pub.html 2>/dev/null | head -1)"
    [ -n "$TITLE" ] && log "pagina: $TITLE"
  elif [ "$PUB" = "301" ] || [ "$PUB" = "302" ]; then
    bad "Publiek geeft $PUB: de tunnel wijst nog naar een origin die doorstuurt."
    log "Zet de tunnel-dienst op HTTP 127.0.0.1:8080."
    FAIL=$((FAIL+1))
  elif [ -n "$PUB" ]; then
    bad "Publiek geeft $PUB."
    FAIL=$((FAIL+1))
  fi
  rm -f /tmp/beatsync-pub.html /tmp/beatsync-pub.hdr
fi

if [ "$FAIL" -eq 0 ]; then
  ok "De lus is weg: Cloudflare-verkeer wordt nu gewoon geserveerd."
  log "Dashboard-dienst: HTTP 127.0.0.1:8080 (poort 80 werkt nu ook)."
else
  bad "Er blijven punten over; zie hierboven."
fi
exit "$FAIL"
