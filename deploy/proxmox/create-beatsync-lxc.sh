#!/usr/bin/env bash
# Maakt een Debian LXC-container op Proxmox VE en publiceert BeatSync Studio
# als website op http(s)://<statisch-ip>/.
#
# Uitvoeren OP DE PROXMOX-HOST als root:
#   ./create-beatsync-lxc.sh
#
# Alle instellingen zijn via omgevingsvariabelen te overschrijven, bijvoorbeeld:
#   STATIC_IP=192.168.1.60/24 GATEWAY=192.168.1.1 ./create-beatsync-lxc.sh
set -euo pipefail

# ----------------------------- instellingen ------------------------------
CTID="${CTID:-}"                                   # leeg = eerstvolgende vrije ID
CT_HOSTNAME="${CT_HOSTNAME:-beatsync}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"      # 'dir'-storage? gebruik bv. local
BRIDGE="${BRIDGE:-vmbr0}"
STATIC_IP="${STATIC_IP:-192.168.1.50/24}"          # ip/prefix, bv. 192.168.1.50/24
GATEWAY="${GATEWAY:-192.168.1.1}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
CORES="${CORES:-1}"
MEMORY="${MEMORY:-512}"                            # MB
SWAP="${SWAP:-256}"                                # MB
DISK="${DISK:-2}"                                  # GB
CT_USER="${CT_USER:-root}"
ENABLE_TLS="${ENABLE_TLS:-1}"                      # 1 = self-signed HTTPS (aanbevolen)
SITE_DIR="/var/www/beatsync"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP_ONLY="${STATIC_IP%%/*}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------- controles ---------------------------------
[ "$(id -u)" -eq 0 ] || die "Draai dit script als root op de Proxmox-host."
command -v pct   >/dev/null || die "pct niet gevonden: dit is geen Proxmox VE-host."
command -v pveam >/dev/null || die "pveam niet gevonden: dit is geen Proxmox VE-host."
[ -f "$SCRIPT_DIR/index.html" ] || die "index.html ontbreekt naast dit script."
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge '$BRIDGE' bestaat niet. Kies een bestaande, bv. BRIDGE=vmbr1."

log "Netwerk controleren: is $IP_ONLY al in gebruik?"
if ping -c1 -W1 "$IP_ONLY" >/dev/null 2>&1; then
  die "$IP_ONLY antwoordt al op ping. Kies een vrij adres met STATIC_IP=..."
fi

# ----------------------------- container-ID ------------------------------
if [ -z "$CTID" ]; then
  CTID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
  [ -n "$CTID" ] || die "Kon geen vrij container-ID bepalen; geef CTID=... mee."
fi
if pct status "$CTID" >/dev/null 2>&1; then
  die "Container $CTID bestaat al. Kies een ander CTID of verwijder hem eerst."
fi
log "Container-ID: $CTID"

# ----------------------------- template ----------------------------------
log "Debian-template zoeken (pveam update kan even duren)…"
pveam update >/dev/null 2>&1 || warn "pveam update mislukte; ik gebruik de lokaal bekende lijst."
# $NF: werkt zowel voor 'system  debian-13-standard_...' als voor één-koloms output.
TEMPLATE="$(pveam available --section system 2>/dev/null \
  | awk '{print $NF}' \
  | grep -E '^debian-(1[23])-standard_.*\.tar' \
  | sort -V | tail -1)"
[ -n "$TEMPLATE" ] || die "Geen Debian 12/13-template gevonden. Controleer 'pveam available --section system'."

if ! pvesm list "$TEMPLATE_STORAGE" --content vztmpl 2>/dev/null | grep -q "$TEMPLATE"; then
  log "Template $TEMPLATE downloaden naar $TEMPLATE_STORAGE…"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || die "Download van $TEMPLATE mislukte."
fi
log "Template: $TEMPLATE"

# ----------------------------- aanmaken ----------------------------------
log "Container aanmaken…"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
  --rootfs "${ROOTFS_STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${STATIC_IP},gw=${GATEWAY},type=veth" \
  --nameserver "$DNS_SERVER" \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --ostype debian \
  --description "BeatSync Studio — statische website (nginx)"

log "Container starten…"
pct start "$CTID"

log "Wachten tot de container klaar is…"
ready=0
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[ "$ready" -eq 1 ] || die "Container $CTID werd niet bereikbaar via pct exec."

# Wacht op netwerk/DNS binnen de container.
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  sleep 2
done

# ----------------------------- nginx -------------------------------------
log "nginx installeren in de container…"
pct exec "$CTID" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq nginx openssl ca-certificates >/dev/null'
pct exec "$CTID" -- nginx -v

log "Site-bestanden plaatsen…"
pct exec "$CTID" -- mkdir -p "$SITE_DIR"
pct push "$CTID" "$SCRIPT_DIR/index.html" "$SITE_DIR/index.html" --perms 644
pct push "$CTID" "$SCRIPT_DIR/nginx-beatsync.conf" /etc/nginx/sites-available/beatsync --perms 644

# ----------------------------- TLS ---------------------------------------
if [ "$ENABLE_TLS" = "1" ]; then
  log "Self-signed certificaat genereren voor $IP_ONLY…"
  pct exec "$CTID" -- mkdir -p /etc/ssl/beatsync
  pct exec "$CTID" -- openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout /etc/ssl/beatsync/key.pem \
    -out /etc/ssl/beatsync/cert.pem \
    -subj "/CN=${IP_ONLY}" \
    -addext "subjectAltName=IP:${IP_ONLY}" >/dev/null 2>&1
  pct exec "$CTID" -- chmod 600 /etc/ssl/beatsync/key.pem
else
  warn "ENABLE_TLS=0: alleen HTTP. Tabblad-audio delen (getDisplayMedia) werkt dan NIET,"
  warn "omdat browsers dat alleen toestaan in een secure context (HTTPS of localhost)."
  # Config zonder TLS-blok klaarzetten.
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

# ----------------------------- activeren ---------------------------------
log "nginx-configuratie activeren…"
pct exec "$CTID" -- rm -f /etc/nginx/sites-enabled/default
pct exec "$CTID" -- ln -sf /etc/nginx/sites-available/beatsync /etc/nginx/sites-enabled/beatsync
if ! pct exec "$CTID" -- nginx -t; then
  die "nginx -t faalde; configuratie is niet geactiveerd."
fi
pct exec "$CTID" -- systemctl enable nginx >/dev/null 2>&1 || true
pct exec "$CTID" -- systemctl restart nginx

# ----------------------------- verifiëren ---------------------------------
log "Vanaf de host controleren of de site antwoordt…"
ok=0
for _ in $(seq 1 15); do
  if curl -kfsS --max-time 4 "https://${IP_ONLY}/healthz" 2>/dev/null | grep -q '^ok$'; then ok=1; break; fi
  if curl -fsS --max-time 4 "http://${IP_ONLY}/healthz" 2>/dev/null | grep -q '^ok$'; then ok=1; break; fi
  sleep 1
done

if [ "$ok" -eq 1 ]; then
  if curl -kfsS --max-time 5 "https://${IP_ONLY}/" 2>/dev/null | grep -qi 'beatsync'; then
    log "Pagina inhoud gecontroleerd: BeatSync Studio wordt geserveerd."
  else
    warn "Healthcheck ok, maar de HTML-inhoud kon niet worden bevestigd."
  fi
else
  warn "Healthcheck vanaf de host mislukte. Test handmatig in de container:"
  warn "  pct exec $CTID -- curl -fsS http://127.0.0.1/healthz"
  warn "Controleer daarna firewall/bridge-instellingen op de host."
fi

cat <<EOF

────────────────────────────────────────────────────────────
 BeatSync Studio draait in container $CTID ($CT_HOSTNAME)

   Website        : $([ "$ENABLE_TLS" = 1 ] && echo "https://${IP_ONLY}/" || echo "http://${IP_ONLY}/")
   Container-IP   : ${STATIC_IP}   gateway ${GATEWAY}

   Bij HTTPS: de browser waarschuwt één keer voor het self-signed
   certificaat. Kies 'Doorgaan' — daarna is de pagina een secure
   context en werkt 'Audio-tab koppelen'.

   Shell in container : pct enter $CTID
   Logs              : pct exec $CTID -- tail -f /var/log/nginx/beatsync.error.log
   Stoppen           : pct shutdown $CTID
   Verwijderen       : pct stop $CTID && pct destroy $CTID
────────────────────────────────────────────────────────────
EOF
