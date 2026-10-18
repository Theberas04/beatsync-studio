#!/usr/bin/env bash
# Richt een BESTAANDE, DRAAIENDE container in als BeatSync-website.
# Wordt aangeroepen door create-beatsync-lxc.sh en fix-lxc-start.sh.
#
#   ./provision-beatsync.sh <container-id> [ip]
#
# Zonder ip-argument wordt het adres uit de container gelezen (DHCP).
set -euo pipefail

CTID="${1:-${CTID:-}}"
FORCED_IP="${2:-${CONTAINER_IP:-}}"
SITE_DIR="/var/www/beatsync"
ENABLE_TLS="${ENABLE_TLS:-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Draai dit als root op de Proxmox-host."
[ -n "$CTID" ] || die "Gebruik: $0 <container-id> [ip]"
[ -f "$SCRIPT_DIR/index.html" ] || die "index.html ontbreekt naast dit script."
[ -f "$SCRIPT_DIR/nginx-beatsync.conf" ] || die "nginx-beatsync.conf ontbreekt naast dit script."
pct status "$CTID" >/dev/null 2>&1 || die "Container $CTID bestaat niet."
[ "$(pct status "$CTID")" = "status: running" ] || die "Container $CTID draait niet. Start hem eerst."

# ----------------------------- IP bepalen ---------------------------------
ct_ip() {
  pct exec "$1" -- ip -4 -o addr show dev eth0 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -1
}

IP_ONLY="$FORCED_IP"
if [ -z "$IP_ONLY" ]; then
  log "IP-adres van container $CTID opvragen (DHCP)…"
  for _ in $(seq 1 30); do
    IP_ONLY="$(ct_ip "$CTID" || true)"
    [ -n "$IP_ONLY" ] && break
    sleep 2
  done
fi
if [ -z "$IP_ONLY" ]; then
  warn "De container heeft nog geen IPv4-adres op eth0."
  echo "Adressen in de container:" >&2
  pct exec "$CTID" -- ip -4 -o addr 2>/dev/null >&2 || true
  cat >&2 <<EOF

Mogelijke oorzaken:
 - De bridge '$BRIDGE' heeft geen DHCP-server (bijvoorbeeld een losse internal bridge).
 - De router geeft geen adres uit; probeer het opnieuw of geef een vast adres:
       pct set $CTID --net0 name=eth0,bridge=vmbr0,ip=192.168.1.50/24,gw=192.168.1.1
       ./provision-beatsync.sh $CTID 192.168.1.50
EOF
  exit 2
fi
log "Containeradres: $IP_ONLY"

# ----------------------------- netwerk afwachten --------------------------
netok=0
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then netok=1; break; fi
  sleep 2
done
[ "$netok" -eq 1 ] || warn "DNS in de container werkt nog niet; apt kan straks falen."

# ----------------------------- nginx -------------------------------------
if ! pct exec "$CTID" -- test -x /usr/sbin/nginx 2>/dev/null; then
  log "nginx installeren in de container…"
  pct exec "$CTID" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq nginx openssl ca-certificates >/dev/null' \
    || die "nginx installeren mislukte (apt/netwerk)."
else
  log "nginx is al geïnstalleerd."
fi

log "Site-bestanden plaatsen…"
pct exec "$CTID" -- mkdir -p "$SITE_DIR"
pct push "$CTID" "$SCRIPT_DIR/index.html" "$SITE_DIR/index.html" --perms 644

# ----------------------------- TLS ---------------------------------------
if [ "$ENABLE_TLS" = "1" ]; then
  pct push "$CTID" "$SCRIPT_DIR/nginx-beatsync.conf" /etc/nginx/sites-available/beatsync --perms 644

  # Certificaat plus een unit die het na een IP-wijziging (DHCP) vernieuwt.
  pct exec "$CTID" -- bash -c 'cat > /usr/local/sbin/beatsync-cert-refresh <<'"'"'SH'"'"'
#!/bin/sh
# Hernieuwt het self-signed certificaat als het DHCP-adres is veranderd.
set -eu
IP=$(ip -4 -o addr show dev eth0 scope global | awk "{print \$4}" | cut -d/ -f1 | head -1)
[ -n "$IP" ] || exit 0
CERT=/etc/ssl/beatsync/cert.pem
if [ -f "$CERT" ] && openssl x509 -in "$CERT" -noout -checkhost "$IP" 2>/dev/null | grep -q "does match"; then
  exit 0
fi
mkdir -p /etc/ssl/beatsync
openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
  -keyout /etc/ssl/beatsync/key.pem -out "$CERT" \
  -subj "/CN=$IP" -addext "subjectAltName=IP:$IP" >/dev/null 2>&1
chmod 600 /etc/ssl/beatsync/key.pem
systemctl reload nginx 2>/dev/null || systemctl restart nginx
SH'
  pct exec "$CTID" -- chmod 755 /usr/local/sbin/beatsync-cert-refresh
  pct exec "$CTID" -- bash -c 'cat > /etc/systemd/system/beatsync-cert.service <<'"'"'UNIT'"'"'
[Unit]
Description=BeatSync: certificaat afstemmen op het huidige IP-adres
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/beatsync-cert-refresh

[Install]
WantedBy=multi-user.target
UNIT'
  log "Certificaat genereren voor $IP_ONLY…"
  pct exec "$CTID" -- /usr/local/sbin/beatsync-cert-refresh || true
  pct exec "$CTID" -- test -f /etc/ssl/beatsync/cert.pem || die "Certificaat aanmaken mislukte."
  pct exec "$CTID" -- systemctl enable beatsync-cert.service >/dev/null 2>&1 || true
else
  warn "ENABLE_TLS=0: alleen HTTP. Tabblad-audio delen werkt dan NIET (geen secure context)."
  pct exec "$CTID" -- bash -c "cat > /etc/nginx/sites-available/beatsync <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root ${SITE_DIR};
    index index.html;
    charset utf-8;
    add_header X-Content-Type-Options \"nosniff\" always;
    add_header Cache-Control \"no-cache\" always;
    location = /healthz { access_log off; default_type text/plain; return 200 \"ok\\n\"; }
    location / { try_files \$uri \$uri/ /index.html; }
}
NGINX"
fi

log "nginx-configuratie activeren…"
pct exec "$CTID" -- rm -f /etc/nginx/sites-enabled/default
pct exec "$CTID" -- ln -sf /etc/nginx/sites-available/beatsync /etc/nginx/sites-enabled/beatsync
pct exec "$CTID" -- nginx -t || die "nginx -t faalde; configuratie niet geactiveerd."
pct exec "$CTID" -- systemctl enable nginx >/dev/null 2>&1 || true
pct exec "$CTID" -- systemctl restart nginx

# ----------------------------- verifiëren ---------------------------------
log "Controleren of de site antwoordt op $IP_ONLY…"
ok=0; scheme="http"
if [ "$ENABLE_TLS" = "1" ]; then scheme="https"; fi
for _ in $(seq 1 15); do
  if curl -kfsS --max-time 4 "${scheme}://${IP_ONLY}/healthz" 2>/dev/null | grep -q '^ok$'; then ok=1; break; fi
  if curl -kfsS --max-time 4 "http://${IP_ONLY}/healthz" 2>/dev/null | grep -q '^ok$'; then ok=1; scheme="http"; break; fi
  sleep 1
done

if [ "$ok" -eq 1 ]; then
  if curl -kfsS --max-time 5 "${scheme}://${IP_ONLY}/" 2>/dev/null | grep -qi 'beatsync'; then
    log "Klaar: BeatSync Studio is bereikbaar op ${scheme}://${IP_ONLY}/"
  else
    warn "Healthcheck ok, maar de HTML-inhoud kon niet worden bevestigd."
  fi
else
  warn "Healthcheck vanaf de host mislukte."
  warn "  pct exec $CTID -- curl -fsS http://127.0.0.1/healthz"
  warn "  pct exec $CTID -- systemctl status nginx --no-pager"
  exit 3
fi

cat <<EOF

────────────────────────────────────────────────────────────
 BeatSync Studio draait in container $CTID

   Website   : ${scheme}://${IP_ONLY}/
   Adres     : via DHCP toegewezen (kan na herstart wijzigen)
   Bij HTTPS : accepteer één keer de certificaatwaarschuwing.
   Shell     : pct enter $CTID
   Logs      : pct exec $CTID -- tail -f /var/log/nginx/beatsync.error.log
────────────────────────────────────────────────────────────
EOF
