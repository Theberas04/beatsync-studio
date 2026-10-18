# BeatSync Studio op Proxmox (LXC met vast 192.168-adres)

Dit pakket zet BeatSync Studio als website in een Debian LXC-container op Proxmox VE.
De container krijgt een **statisch IP** in je 192.168-netwerk en serveert de pagina via nginx.

## Bestanden

| Bestand | Doel |
|---|---|
| `index.html` | De volledige app (één bestand). |
| `create-beatsync-lxc.sh` | Maakt de container, installeert nginx, plaatst de site, zet HTTPS op. |
| `nginx-beatsync.conf` | nginx-site (HTTP → HTTPS, statische bestanden). |
| `update-site.sh` | Werkt een bestaande container bij met een nieuwe `index.html`. |

## Installeren met één commando (vanaf GitHub)

Op de Proxmox-host als root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/install.sh)
```

Dit haalt de bestanden op, controleert ze en maakt daarna de container aan.
Eigen netwerkwaarden meegeven kan op dezelfde regel:

```bash
STATIC_IP=192.168.2.50/24 GATEWAY=192.168.2.1 \
  bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/install.sh)
```

Alleen downloaden om te kijken wat er staat (maakt niets aan):

```bash
FETCH_ONLY=1 bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/install.sh)
```

Let op: gebruik `bash <(curl ...)`, niet `curl ... | bash`. Bij de pijpvorm raakt het
toetsenbordinvoer kwijt, waardoor de installatie kan blijven hangen.

## Snelstart


Kopieer deze map naar je Proxmox-host (bijvoorbeeld naar `/root/beatsync-proxmox`) en
voer uit als root:

```bash
cd /root/beatsync-proxmox
chmod +x create-beatsync-lxc.sh update-site.sh
./create-beatsync-lxc.sh
```

Standaard wordt `192.168.1.50/24` met gateway `192.168.1.1` gebruikt. Wijkt je netwerk af,
geef de waarden dan mee:

```bash
STATIC_IP=192.168.2.50/24 GATEWAY=192.168.2.1 ./create-beatsync-lxc.sh
```

Daarna is de site bereikbaar op `https://192.168.1.50/`.

## Instellingen (omgevingsvariabelen)

| Variabele | Standaard | Betekenis |
|---|---|---|
| `CTID` | automatisch | Container-ID. |
| `CT_HOSTNAME` | `beatsync` | Hostnaam van de container. |
| `STATIC_IP` | `192.168.1.50/24` | Vast IP met prefixlengte. |
| `GATEWAY` | `192.168.1.1` | Gateway van je netwerk. |
| `DNS_SERVER` | `1.1.1.1` | DNS in de container (nodig voor apt). |
| `BRIDGE` | `vmbr0` | Proxmox-bridge waar je LAN op zit. |
| `TEMPLATE_STORAGE` | `local` | Storage voor de LXC-template. |
| `ROOTFS_STORAGE` | `local-lvm` | Storage voor de schijf (gebruik `local` bij alleen dir-storage). |
| `CORES` / `MEMORY` / `SWAP` / `DISK` | `1` / `512` / `256` / `2` | Resources (MB/GB). |
| `ENABLE_TLS` | `1` | Self-signed HTTPS. Zet niet op `0` als je tabblad-audio wilt gebruiken. |

## Waarom HTTPS, ook op een LAN-adres?

De functie **Audio-tab koppelen** gebruikt `navigator.mediaDevices.getDisplayMedia()`.
Browsers staan dat alleen toe in een *secure context*: HTTPS of `localhost`.
Op `http://192.168.1.50` weigert Chrome die functie dus, ook al laadt de pagina prima.

Daarom zet het script standaard een self-signed certificaat neer. Je browser waarschuwt
één keer ("Niet veilig" → **Doorgaan**); daarna werkt de audiokoppeling normaal.
Wil je die waarschuwing weg hebben, gebruik dan een eigen certificaat of een
reverse proxy met een echt certificaat.

## Bijwerken

Nieuwe `index.html` in deze map zetten en:

```bash
./update-site.sh 105        # 105 = het container-ID
```

## Beheer

```bash
pct status 105                 # status
pct enter 105                  # shell in de container
pct exec 105 -- tail -f /var/log/nginx/beatsync.error.log
pct shutdown 105               # stoppen
pct stop 105 && pct destroy 105  # definitief verwijderen
```

## Als het niet werkt

- **"Container bestaat al"** → kies een ander nummer: `CTID=120 ./create-beatsync-lxc.sh`.
- **"IP antwoordt al op ping"** → het adres is bezet; kies een vrij adres in je DHCP-bereik-vrije zone.
- **Site niet bereikbaar vanaf je pc** → test op de host: `curl -k https://192.168.1.50/healthz`.
  Werkt dat wel, dan blokkeert je eigen firewall of zit je op een ander VLAN.
- **`nginx -t` faalt** → het script stopt vóór activering; draai `pct exec 105 -- nginx -t` voor details.
- **Audiokoppeling grijs/geweigerd** → je zit op HTTP in plaats van HTTPS.
- **`apt-get` faalt in de container** → controleer `DNS_SERVER` en of de container via de gateway kan uitgaat.

## Wat het script niet doet

- Geen port-forward of routerwijziging: de site is bedoeld voor je LAN.
- Geen DHCP-reservering; het IP staat statisch in de containerconfiguratie.
- Geen automatische updates van de app; gebruik `update-site.sh`.
