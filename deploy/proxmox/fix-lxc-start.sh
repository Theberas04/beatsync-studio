#!/usr/bin/env bash
# Repareert een BeatSync-container die niet wil starten en zet hem daarna op DHCP.
#
#   ./fix-lxc-start.sh 102                 # repareren + DHCP + website inrichten
#   SET_DHCP=0 ./fix-lxc-start.sh 102      # vast IP laten staan
#   RECREATE=1 ./fix-lxc-start.sh 102      # opnieuw opbouwen met Debian 12 (wist de container)
set -euo pipefail

CTID="${1:-${CTID:-}}"
SET_DHCP="${SET_DHCP:-1}"
RECREATE="${RECREATE:-0}"
DEBIAN_MAJOR="${DEBIAN_MAJOR:-12}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Draai dit als root op de Proxmox-host."
[ -n "$CTID" ] || die "Gebruik: $0 <container-id>"
command -v pct >/dev/null || die "pct niet gevonden: dit is geen Proxmox VE-host."
pct status "$CTID" >/dev/null 2>&1 || die "Container $CTID bestaat niet. Maak hem aan met ./create-beatsync-lxc.sh"
CONF="/etc/pve/lxc/${CTID}.conf"

PVE_V="$(pveversion 2>/dev/null | sed -n 's|pve-manager/\([0-9]*\.[0-9]*\).*|\1|p')"
OSTEMPLATE="$(pct config "$CTID" | sed -n 's/^ostemplate: //p')"

log "Container $CTID — Proxmox $PVE_V — template $(basename "${OSTEMPLATE:-onbekend}")"

# ----------------------------- te nieuwe distributie? --------------------
if printf '%s' "$OSTEMPLATE" | grep -q 'debian-13'; then
  if [ -n "$PVE_V" ] && [ "$(printf '%s\n8.2\n' "$PVE_V" | sort -V | head -1)" = "$PVE_V" ] && [ "$PVE_V" != "8.2" ]; then
    warn "Debian 13 op Proxmox $PVE_V is meestal de oorzaak van deze startfout."
    warn "Debian 13 vereist Proxmox 8.2 of nieuwer (niegere LXC)."
    if [ "$RECREATE" = "1" ]; then
      log "RECREATE=1: container $CTID verwijderen en opnieuw opbouwen met Debian $DEBIAN_MAJOR…"
      pct stop "$CTID" 2>/dev/null || true
      pct destroy "$CTID"
      exec env CTID="$CTID" DEBIAN_MAJOR=12 "$SCRIPT_DIR/create-beatsync-lxc.sh"
    fi
    cat >&2 <<EOF

Oplossing: bouw de container opnieuw op met Debian 12 (de container is nog leeg):

    pct stop $CTID 2>/dev/null; pct destroy $CTID
    DEBIAN_MAJOR=12 ./create-beatsync-lxc.sh

Of laat dit script het doen (verwijdert container $CTID):

    RECREATE=1 ./fix-lxc-start.sh $CTID
EOF
    exit 1
  fi
fi

# ----------------------------- DHCP instellen ----------------------------
if [ "$SET_DHCP" = "1" ]; then
  CUR_NET="$(pct config "$CTID" | sed -n 's/^net0: //p')"
  if printf '%s' "$CUR_NET" | grep -q 'ip=dhcp'; then
    log "Container staat al op DHCP."
  else
    BRIDGE="$(printf '%s' "$CUR_NET" | sed -n 's/.*bridge=\([^,]*\).*/\1/p')"
    BRIDGE="${BRIDGE:-vmbr0}"
    if [ "$(pct status "$CTID")" = "status: running" ]; then
      warn "Container draait; netwerk wijzigen gebeurt na een korte herstart."
      pct stop "$CTID" >/dev/null 2>&1 || true
      sleep 2
    fi
    log "Netwerk omzetten naar DHCP op $BRIDGE…"
    pct set "$CTID" --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,type=veth"
    log "Container gebruikt nu DHCP in plaats van een vast adres."
  fi
fi

# ----------------------------- starten met fallbacks ---------------------
start_ct() {
  local out
  if out="$(pct start "$1" 2>&1)"; then return 0; fi
  printf '%s\n' "$out" >&2
  return 1
}

if [ "$(pct status "$CTID")" = "status: running" ]; then
  log "Container draait al."
else
  log "Container starten…"
  if ! start_ct "$CTID"; then
    warn "Poging 1 mislukte. AppArmor ontspannen en opnieuw proberen…"
    grep -q '^lxc.apparmor.profile' "$CONF" 2>/dev/null || printf 'lxc.apparmor.profile: unconfined\n' >> "$CONF"
    if ! start_ct "$CTID"; then
      warn "Poging 2 mislukte. 'nesting' toevoegen en opnieuw proberen…"
      grep -q '^features:' "$CONF" 2>/dev/null || printf 'features: nesting=1\n' >> "$CONF"
      if ! start_ct "$CTID"; then
        echo "--------- pct config $CTID ---------"; pct config "$CTID" || true
        echo "--------- journal ------------------"
        journalctl -u "pve-container@${CTID}" --no-pager -n 40 2>/dev/null || true
        echo "--------- apparmor (dmesg) ---------"
        dmesg 2>/dev/null | tail -20 || true
        cat >&2 <<EOF

[fout] Container $CTID start nog steeds niet.

Controleer op de host:
    aa-status                      # is AppArmor actief?
    lvs && df -h                   # ruimte op de rootfs/thin pool?
    pvesm status                   # storage gezond?
    pct config $CTID               # net0, rootfs, unprivileged

Als de container leeg is, is opnieuw opbouwen met Debian 12 meestal het snelst:
    RECREATE=1 ./fix-lxc-start.sh $CTID
EOF
        exit 1
      fi
    fi
  fi
  log "Container gestart."
fi

# ----------------------------- klaar voor inrichting ---------------------
ready=0
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[ "$ready" -eq 1 ] || die "Container draait maar is niet bereikbaar via pct exec."

log "Website (opnieuw) inrichten…"
ENABLE_TLS="${ENABLE_TLS:-1}" "$SCRIPT_DIR/provision-beatsync.sh" "$CTID"
