#!/usr/bin/env bash
# Maakt een Debian LXC-container op Proxmox VE en publiceert BeatSync Studio
# als website. Standaard krijgt de container een IP via DHCP van je router.
#
# Uitvoeren OP DE PROXMOX-HOST als root:
#   ./create-beatsync-lxc.sh
#
# Eigen waarden meegeven, bijvoorbeeld:
#   BRIDGE=vmbr1 MEMORY=1024 ./create-beatsync-lxc.sh
#   STATIC_IP=192.168.1.50/24 GATEWAY=192.168.1.1 ./create-beatsync-lxc.sh   # vast IP
set -euo pipefail

# ----------------------------- instellingen ------------------------------
CTID="${CTID:-}"                                   # leeg = eerstvolgende vrije ID
CT_HOSTNAME="${CT_HOSTNAME:-beatsync}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"      # dir-storage? gebruik bv. local
BRIDGE="${BRIDGE:-vmbr0}"
STATIC_IP="${STATIC_IP:-}"                         # leeg = DHCP (standaard)
GATEWAY="${GATEWAY:-}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
CORES="${CORES:-1}"
MEMORY="${MEMORY:-512}"                            # MB
SWAP="${SWAP:-256}"                                # MB
DISK="${DISK:-2}"                                  # GB
ENABLE_TLS="${ENABLE_TLS:-1}"
# Debian 12 is de veilige keuze: Debian 13 (trixie) vereist Proxmox 8.2+ en
# faalt op oudere hosts bij 'pct start' met een vroege spawn-fout.
DEBIAN_MAJOR="${DEBIAN_MAJOR:-12}"
# nesting is voor een statische nginx-site niet nodig en kan starten breken.
FEATURES="${FEATURES:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------- controles ---------------------------------
[ "$(id -u)" -eq 0 ] || die "Draai dit script als root op de Proxmox-host."
command -v pct   >/dev/null || die "pct niet gevonden: dit is geen Proxmox VE-host."
command -v pveam >/dev/null || die "pveam niet gevonden: dit is geen Proxmox VE-host."
[ -f "$SCRIPT_DIR/index.html" ] || die "index.html ontbreekt naast dit script."
[ -f "$SCRIPT_DIR/provision-beatsync.sh" ] || die "provision-beatsync.sh ontbreekt naast dit script."
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge '$BRIDGE' bestaat niet. Kies een bestaande, bv. BRIDGE=vmbr1."

if [ -n "$STATIC_IP" ]; then
  [ -n "$GATEWAY" ] || die "Bij STATIC_IP hoort ook GATEWAY=..."
  log "Netwerk: vast adres $STATIC_IP via $GATEWAY"
  if ping -c1 -W1 "${STATIC_IP%%/*}" >/dev/null 2>&1; then
    die "${STATIC_IP%%/*} antwoordt al op ping. Kies een vrij adres."
  fi
else
  log "Netwerk: DHCP (de router wijst een adres toe)"
  warn "Een DHCP-adres kan na een herstart veranderen; het certificaat wordt dan"
  warn "automatisch bijgewerkt. Wil je een vast adres, geef STATIC_IP=... mee."
fi

# ----------------------------- container-ID ------------------------------
if [ -z "$CTID" ]; then
  CTID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
  [ -n "$CTID" ] || die "Kon geen vrij container-ID bepalen; geef CTID=... mee."
fi
if pct status "$CTID" >/dev/null 2>&1; then
  die "Container $CTID bestaat al. Gebruik ./fix-lxc-start.sh $CTID om hem te repareren."
fi
log "Container-ID: $CTID"

# ----------------------------- template ----------------------------------
log "Debian $DEBIAN_MAJOR-template zoeken…"
pveam update >/dev/null 2>&1 || warn "pveam update mislukte; ik gebruik de lokaal bekende lijst."

pick_template() {
  pveam available --section system 2>/dev/null \
    | awk '{print $NF}' \
    | grep -E "^debian-$1-standard_.*\.tar" \
    | sort -V | tail -1
}

TEMPLATE="$(pick_template "$DEBIAN_MAJOR")"
if [ -z "$TEMPLATE" ]; then
  warn "Geen Debian $DEBIAN_MAJOR-template gevonden; ik kijk naar een andere versie."
  for alt in 12 13; do
    TEMPLATE="$(pick_template "$alt")"
    [ -n "$TEMPLATE" ] && { warn "Ik gebruik $TEMPLATE."; break; }
  done
fi
[ -n "$TEMPLATE" ] || die "Geen Debian-template gevonden. Controleer 'pveam available --section system'."

if ! pvesm list "$TEMPLATE_STORAGE" --content vztmpl 2>/dev/null | grep -q "$TEMPLATE"; then
  log "Template $TEMPLATE downloaden naar $TEMPLATE_STORAGE…"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || die "Download van $TEMPLATE mislukte."
fi
log "Template: $TEMPLATE"

# ----------------------------- aanmaken ----------------------------------
log "Container aanmaken…"
if [ -n "$STATIC_IP" ]; then
  NET0="name=eth0,bridge=${BRIDGE},ip=${STATIC_IP},gw=${GATEWAY},type=veth"
else
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp,type=veth"
fi

create_args=(
  "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
  --hostname "$CT_HOSTNAME"
  --cores "$CORES" --memory "$MEMORY" --swap "$SWAP"
  --rootfs "${ROOTFS_STORAGE}:${DISK}"
  --net0 "$NET0"
  --nameserver "$DNS_SERVER"
  --unprivileged 1
  --onboot 1
  --ostype debian
  --description "BeatSync Studio — statische website (nginx)"
)
[ -n "$FEATURES" ] && create_args+=(--features "$FEATURES")
pct create "${create_args[@]}"

# ----------------------------- starten met fallback ----------------------
start_ct() {
  local out
  if out="$(pct start "$1" 2>&1)"; then return 0; fi
  printf '%s\n' "$out" >&2
  return 1
}

if start_ct "$CTID"; then
  log "Container gestart."
else
  warn "Starten mislukte. Ik probeer AppArmor te ontspannen en start opnieuw…"
  CONF="/etc/pve/lxc/${CTID}.conf"
  grep -q '^lxc.apparmor.profile' "$CONF" 2>/dev/null || printf 'lxc.apparmor.profile: unconfined\n' >> "$CONF"
  if start_ct "$CTID"; then
    log "Container gestart met lxc.apparmor.profile: unconfined (workaround)."
  else
    echo "------------- pveversion -------------"; pveversion || true
    echo "------------- config ---------------"; pct config "$CTID" || true
    echo "------------- journal -------------"
    journalctl -u "pve-container@${CTID}" --no-pager -n 30 2>/dev/null || true
    echo "------------- apparmor in dmesg ----"
    dmesg 2>/dev/null | tail -15 || true
    cat >&2 <<EOF

[fout] Container $CTID start niet.

Meest voorkomende oorzaken bij een verse container:

 1. Te nieuwe distributie voor je Proxmox-versie.
    Debian 13 vereist Proxmox 8.2+ (LXC 5.0.3+). Op Proxmox 7.x of 8.0/8.1
    faalt 'pct start' direct met 'sync_wait ... expected sequence number'.
        pct destroy $CTID
        DEBIAN_MAJOR=12 ./create-beatsync-lxc.sh

 2. AppArmor blokkeert de container: controleer 'aa-status' en
    'dmesg | grep -i apparmor'.

 3. Storage-probleem met de rootfs: controleer 'df -h', 'lvs', 'pvesm status'.

De container bestaat nog (ongestart). Repareren kan met:
    ./fix-lxc-start.sh $CTID
EOF
    exit 1
  fi
fi

log "Wachten tot de container klaar is…"
ready=0
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[ "$ready" -eq 1 ] || die "Container $CTID werd niet bereikbaar via pct exec."

# ----------------------------- inrichten ---------------------------------
log "Website inrichten…"
ENABLE_TLS="$ENABLE_TLS" "$SCRIPT_DIR/provision-beatsync.sh" "$CTID" \
  || die "Inrichten mislukte. Los het op en draai daarna: ./provision-beatsync.sh $CTID"
