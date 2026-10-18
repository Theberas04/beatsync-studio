#!/usr/bin/env bash
# Controleert waarom een Cloudflare-hostname niet werkt: origin, tunnel en
# certificaat. Draait op de Proxmox-host als root.
#
#   ./check-tunnel.sh 102
#   ./check-tunnel.sh 102 nep.muziek.werdensmedia.com
set -uo pipefail

CTID="${1:-${CTID:-}}"
PUBLIC_HOST="${2:-${PUBLIC_HOST:-}}"
SITE_DIR="/var/www/beatsync"

ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
info() { printf '     %s\n' "$*"; }
head_() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { bad "Draai dit als root op de Proxmox-host."; exit 1; }
[ -n "$CTID" ] || { bad "Gebruik: $0 <container-id> [hostname]"; exit 1; }
command -v pct >/dev/null || { bad "pct niet gevonden: dit is geen Proxmox VE-host."; exit 1; }

FAIL=0

head_ "1. Container"
if ! pct status "$CTID" >/dev/null 2>&1; then
  bad "Container $CTID bestaat niet."
  exit 1
fi
if [ "$(pct status "$CTID")" = "status: running" ]; then
  ok "Container $CTID draait."
  IP="$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  info "IP: ${IP:-onbekend}"
else
  bad "Container $CTID draait niet. Start hem: pct start $CTID"
  exit 1
fi

head_ "2. nginx en de loopback-origin (die de tunnel gebruikt)"
if pct exec "$CTID" -- test -x /usr/sbin/nginx 2>/dev/null; then
  ok "nginx is geïnstalleerd."
else
  bad "nginx ontbreekt in de container."
  FAIL=$((FAIL+1))
fi
if pct exec "$CTID" -- grep -q '127.0.0.1:8080' /etc/nginx/sites-available/beatsync 2>/dev/null; then
  ok "nginx luistert op 127.0.0.1:8080 (tunnel-origin)."
else
  bad "nginx heeft GEEN 127.0.0.1:8080-listener; de tunnel kan de site dan niet bereiken."
  info "Oplossing: ./add-cloudflare-tunnel.sh $CTID  (voegt het blok toe)"
  FAIL=$((FAIL+1))
fi
if pct exec "$CTID" -- curl -fsS --max-time 5 http://127.0.0.1:8080/healthz 2>/dev/null | grep -q '^ok$'; then
  ok "Origin antwoordt: http://127.0.0.1:8080/healthz"
else
  bad "Origin 127.0.0.1:8080 antwoordt niet."
  info "Controleer: pct exec $CTID -- nginx -t && pct exec $CTID -- systemctl status nginx --no-pager"
  FAIL=$((FAIL+1))
fi
if pct exec "$CTID" -- test -s "$SITE_DIR/index.html" 2>/dev/null; then
  ok "index.html staat in $SITE_DIR."
else
  bad "index.html ontbreekt in $SITE_DIR."
  FAIL=$((FAIL+1))
fi

head_ "3. Lokaal HTTPS (LAN)"
if pct exec "$CTID" -- test -f /etc/ssl/beatsync/cert.pem 2>/dev/null; then
  SUBJ="$(pct exec "$CTID" -- openssl x509 -in /etc/ssl/beatsync/cert.pem -noout -subject 2>/dev/null | sed 's/^subject=//')"
  ok "Certificaat aanwezig: ${SUBJ:-(onderwerp onbekend)}"
else
  warn "Geen (self-signed) certificaat; LAN-HTTPS werkt dan niet."
fi

head_ "4. cloudflared"
if pct exec "$CTID" -- test -x /usr/bin/cloudflared 2>/dev/null; then
  VER="$(pct exec "$CTID" -- cloudflared --version 2>/dev/null | head -1)"
  ok "Geïnstalleerd: ${VER:-cloudflared (versie onbekend)}"
else
  bad "cloudflared is niet geïnstalleerd."
  info "Oplossing: ./add-cloudflare-tunnel.sh $CTID"
  FAIL=$((FAIL+1))
fi
if pct exec "$CTID" -- systemctl is-active --quiet cloudflared 2>/dev/null; then
  ok "Service cloudflared is actief."
  CONNS="$(pct exec "$CTID" -- bash -c 'journalctl -u cloudflared --no-pager -n 200 2>/dev/null | grep -c "Registered tunnel connection"' 2>/dev/null | tr -d '\r')"
  if [ "${CONNS:-0}" -gt 0 ] 2>/dev/null; then
    ok "Tunnelverbindingen geregistreerd in het log ($CONNS regels)."
  else
    warn "Service draait, maar ik zie geen 'Registered tunnel connection' in het log."
    info "Laatste regels:"
    pct exec "$CTID" -- journalctl -u cloudflared --no-pager -n 12 2>/dev/null | sed 's/^/       /'
    FAIL=$((FAIL+1))
  fi
else
  bad "Service cloudflared is niet actief."
  info "Controleer: pct exec $CTID -- journalctl -u cloudflared -n 30 --no-pager"
  FAIL=$((FAIL+1))
fi

# Tunnel-ID uit de token in de systemd-unit halen (geen secret tonen).
TID=""; ACC=""
UNIT=/etc/systemd/system/cloudflared.service
if pct exec "$CTID" -- test -f "$UNIT" 2>/dev/null; then
  RAW="$(pct exec "$CTID" -- grep -oE '[A-Za-z0-9+/=_-]{80,}' "$UNIT" 2>/dev/null | head -1 | tr -d '\r')"
  if [ -n "$RAW" ]; then
    # URL-safe base64: '-' = '+' en '_' = '/', en de padding kan ontbreken.
    DEC="$(printf '%s' "$RAW" | tr -- '-_' '+/' \
      | awk '{ p = length($0) % 4; if (p == 2) $0 = $0 "=="; else if (p == 3) $0 = $0 "="; print }' \
      | base64 -d 2>/dev/null || true)"
    TID="$(printf '%s' "$DEC" | sed -n 's/.*"t": *"\([^"]*\)".*/\1/p')"
    ACC="$(printf '%s' "$DEC" | sed -n 's/.*"a": *"\([^"]*\)".*/\1/p')"
  fi
fi
if [ -n "$TID" ]; then
  ok "Tunnel-ID: $TID"
  [ -n "$ACC" ] && info "Dashboard: https://one.dash.cloudflare.com/$ACC/networks/tunnels/$TID"
else
  warn "Kon de tunnel-ID niet uit de service halen (ander serviceformaat?)."
fi

head_ "5. Publieke hostname"
if [ -n "$PUBLIC_HOST" ]; then
  LABELS="$(awk -F. '{print NF}' <<<"$PUBLIC_HOST")"
  info "Hostname: $PUBLIC_HOST ($LABELS labels)"
  # Universal SSL dekt alleen het apex en één subniveau (*.domein.tld).
  if [ "$LABELS" -gt 3 ]; then
    bad "Deze hostname is te diep voor het gratis Cloudflare-certificaat."
    info "Universal SSL dekt '*.werdensmedia.com' = één subniveau (dus wel nep.werdensmedia.com,"
    info "maar niet nep.muziek.werdensmedia.com). Gevolg: TLS-handshake faalt (alert 40)."
    info "Oplossing A (gratis): gebruik één subniveau, bv. nep-werdensmedia.werdensmedia.com"
    info "Oplossing B (betaald): Total TLS of Advanced Certificate Manager aanzetten voor de zone."
    FAIL=$((FAIL+1))
  else
    ok "Hostnamediepte is goed voor Universal SSL."
  fi
  info "Zet in het dashboard bij Public Hostname:"
  info "   Service: HTTP    URL: 127.0.0.1:8080"
fi

head_ "Samenvatting"
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32mAlles lijkt in orde aan de origin-kant.\033[0m\n'
  info "Blijft de site stuk, dan zit het in de Cloudflare-instellingen van de"
  info "public hostname (service-URL) of in de certificaatdekking van de hostname."
else
  printf '\033[1;31mEr zijn %s punt(en) om op te lossen (zie hierboven).\033[0m\n' "$FAIL"
fi
exit "$FAIL"
