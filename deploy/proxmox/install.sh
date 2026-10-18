#!/usr/bin/env bash
# BeatSync Studio — installer die de bestanden van GitHub haalt en daarna de
# LXC-container op Proxmox VE aanmaakt.
#
# Draaien op de Proxmox-host als root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/install.sh)
#
# Eigen netwerkwaarden meegeven:
#   STATIC_IP=192.168.2.50/24 GATEWAY=192.168.2.1 \
#     bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/install.sh)
#
# Alleen downloaden (niets aanmaken, om te kijken wat er staat):
#   FETCH_ONLY=1 bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/install.sh)
set -euo pipefail

REPO="${REPO:-Theberas04/beatsync-studio}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
TARGET_DIR="${TARGET_DIR:-/root/beatsync-proxmox}"
FETCH_ONLY="${FETCH_ONLY:-0}"

FILES=(
  "deploy/proxmox/create-beatsync-lxc.sh"
  "deploy/proxmox/provision-beatsync.sh"
  "deploy/proxmox/fix-lxc-start.sh"
  "deploy/proxmox/add-cloudflare-tunnel.sh"
  "deploy/proxmox/check-tunnel.sh"
  "deploy/proxmox/nginx-beatsync.conf"
  "deploy/proxmox/update-site.sh"
  "deploy/proxmox/README.md"
  "index.html"
)

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fout]\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------- controles ---------------------------------
if [ "$FETCH_ONLY" != "1" ]; then
  [ "$(id -u)" -eq 0 ] || die "Draai dit als root op de Proxmox-host."
  command -v pct >/dev/null 2>&1 || die "pct niet gevonden: dit is geen Proxmox VE-host."
  [ -e /etc/pve ] || die "/etc/pve ontbreekt: dit is geen Proxmox VE-host."
fi

command -v curl >/dev/null 2>&1 || die "curl ontbreekt. Installeer het (apt-get install curl) en probeer opnieuw."

log "Bestanden ophalen uit github.com/${REPO} (${BRANCH})…"
mkdir -p "$TARGET_DIR"

for f in "${FILES[@]}"; do
  out="$TARGET_DIR/$(basename "$f")"
  url="${RAW_BASE}/${f}"
  if ! curl -fsSL --retry 3 --max-time 60 "$url" -o "$out"; then
    die "Kon $url niet downloaden. Bestaat de repo/branch en is de repo openbaar?"
  fi
  [ -s "$out" ] || die "$url gaf een leeg bestand."
  log "  $(basename "$f")  ($(wc -c <"$out") bytes)"
done

# ----------------------------- controleer inhoud --------------------------
log "Inhoud controleren…"
grep -qi 'beatsync' "$TARGET_DIR/index.html"       || die "index.html lijkt niet de BeatSync-pagina."
grep -q 'server {'  "$TARGET_DIR/nginx-beatsync.conf" || die "nginx-config lijkt onvolledig."
grep -q 'pct create' "$TARGET_DIR/create-beatsync-lxc.sh" || die "installatiescript lijkt onvolledig."
for script in create-beatsync-lxc.sh provision-beatsync.sh fix-lxc-start.sh \
                 add-cloudflare-tunnel.sh check-tunnel.sh update-site.sh; do
  bash -n "$TARGET_DIR/$script" || die "$script heeft een syntaxfout."
done
log "  alle bestanden compleet en syntactisch correct"

chmod +x "$TARGET_DIR/create-beatsync-lxc.sh" "$TARGET_DIR/provision-beatsync.sh" \
         "$TARGET_DIR/fix-lxc-start.sh" "$TARGET_DIR/add-cloudflare-tunnel.sh" "$TARGET_DIR/check-tunnel.sh" \
         "$TARGET_DIR/update-site.sh"

if [ "$FETCH_ONLY" = "1" ]; then
  log "FETCH_ONLY=1: bestanden staan in $TARGET_DIR, er is niets aangemaakt."
  exit 0
fi

# ----------------------------- installeren ---------------------------------
log "Container aanmaken (dit duurt een paar minuten)…"
cd "$TARGET_DIR"
exec ./create-beatsync-lxc.sh
