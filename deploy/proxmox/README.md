# BeatSync Studio op Proxmox (LXC, IP via DHCP)

Dit pakket zet BeatSync Studio als website in een Debian LXC-container op Proxmox VE.
De container krijgt standaard **een IP via DHCP** van je router en serveert de pagina via nginx.

## Bestanden

| Bestand | Doel |
|---|---|
| `index.html` | De volledige app (één bestand). |
| `create-beatsync-lxc.sh` | Maakt de container (Debian 12), start hem en richt de site in. |
| `provision-beatsync.sh` | Installeert nginx, plaatst de site, regelt HTTPS in een bestaande container. |
| `fix-lxc-start.sh` | Repareert een container die niet start en zet hem op DHCP. |
| `nginx-beatsync.conf` | nginx-site (HTTP → HTTPS, statische bestanden). |
| `update-site.sh` | Werkt een bestaande container bij met een nieuwe `index.html`. |

## Installeren met één commando (vanaf GitHub)

Op de Proxmox-host als root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/install.sh)
```

Dit haalt de bestanden op, controleert ze en maakt daarna de container aan.
Alleen downloaden om te kijken wat er staat (maakt niets aan):

```bash
FETCH_ONLY=1 bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/install.sh)
```

Let op: gebruik `bash <(curl ...)`, niet `curl ... | bash`. Bij de pijpvorm raakt het
toetsenbordinvoer kwijt, waardoor de installatie kan blijven hangen.

## Netwerk: DHCP of vast

- **Standaard: DHCP.** De router wijst een adres toe. Het script leest dat adres uit de
  container, maakt daar het certificaat voor en print de URL die je moet openen.
- **Vast adres** kan ook:

  ```bash
  STATIC_IP=192.168.1.50/24 GATEWAY=192.168.1.1 ./create-beatsync-lxc.sh
  ```

Omdat een DHCP-adres kan wijzigen, installeert het script in de container een kleine
systemd-unit (`beatsync-cert.service`) die na het opstarten controleert of het certificaat
nog bij het huidige IP past. Zo niet, dan wordt het certificaat opnieuw gemaakt en nginx
herladen. Het adres zelf vind je met `pct exec <id> -- ip -4 addr show eth0`.

## Een container die niet start repareren

Bij een startfout als

```
sync_wait: 34 An error occurred in another process (expected sequence number 7)
__lxc_start: 2288 Failed to spawn container
```

draai je op de host:

```bash
./fix-lxc-start.sh 102          # 102 = het container-ID
```

Het script:

1. zet het netwerk op DHCP (tenzij `SET_DHCP=0`),
2. probeert te starten, en herhaalt dat met `lxc.apparmor.profile: unconfined` en daarna
   met `features: nesting=1`,
3. meldt het wanneer een te nieuwe distributie de oorzaak is (Debian 13 vereist Proxmox 8.2+),
4. richt de website in zodra de container loopt.

Lukt starten echt niet en is de container nog leeg, bouw hem dan opnieuw op met Debian 12:

```bash
RECREATE=1 ./fix-lxc-start.sh 102     # verwijdert container 102
```

## Instellingen (omgevingsvariabelen)

| Variabele | Standaard | Betekenis |
|---|---|---|
| `CTID` | automatisch | Container-ID. |
| `CT_HOSTNAME` | `beatsync` | Hostnaam van de container. |
| `STATIC_IP` | *leeg* (DHCP) | Vast adres met prefixlengte, bv. `192.168.1.50/24`. |
| `GATEWAY` | *leeg* | Gateway; verplicht bij `STATIC_IP`. |
| `DNS_SERVER` | `1.1.1.1` | DNS in de container (nodig voor apt). |
| `BRIDGE` | `vmbr0` | Proxmox-bridge waar je LAN op zit. |
| `TEMPLATE_STORAGE` | `local` | Storage voor de LXC-template. |
| `ROOTFS_STORAGE` | `local-lvm` | Storage voor de schijf (gebruik `local` bij alleen dir-storage). |
| `CORES` / `MEMORY` / `SWAP` / `DISK` | `1` / `512` / `256` / `2` | Resources (MB/GB). |
| `DEBIAN_MAJOR` | `12` | `13` alleen op Proxmox 8.2 of nieuwer. |
| `ENABLE_TLS` | `1` | Self-signed HTTPS. Zet niet op `0` als je tabblad-audio wilt gebruiken. |
| `FEATURES` | *leeg* | Extra `pct`-features, bv. `nesting=1`. |

## Waarom HTTPS, ook op een LAN-adres?

De functie **Audio-tab koppelen** gebruikt `navigator.mediaDevices.getDisplayMedia()`.
Browsers staan dat alleen toe in een *secure context*: HTTPS of `localhost`.
Op `http://192.168.1.x` weigert Chrome die functie dus, ook al laadt de pagina prima.

Daarom zet het script standaard een self-signed certificaat neer. Je browser waarschuwt
één keer ("Niet veilig" → **Doorgaan**); daarna werkt de audiokoppeling normaal.

## Bijwerken

Nieuwe `index.html` in deze map zetten en:

```bash
./update-site.sh 102        # 102 = het container-ID
```

## Beheer

```bash
pct status 102                 # status
pct enter 102                  # shell in de container
pct exec 102 -- ip -4 addr show eth0        # DHCP-adres opvragen
pct exec 102 -- tail -f /var/log/nginx/beatsync.error.log
pct shutdown 102               # stoppen
pct stop 102 && pct destroy 102  # definitief verwijderen
```

## Als het niet werkt

- **`sync_wait ... expected sequence number`** → zie *Een container die niet start repareren*.
- **Container krijgt geen IP** → heeft de bridge wel DHCP? Controleer op de host `ip -br a`
  en of je router adressen uitgeeft. Of geef een vast adres mee.
- **Site niet bereikbaar vanaf je pc** → test op de host:
  `curl -k https://<container-ip>/healthz`. Werkt dat wel, dan blokkeert je firewall of VLAN.
- **`nginx -t` faalt** → het script stopt vóór activering; `pct exec 102 -- nginx -t` geeft details.
- **Audiokoppeling geweigerd** → je zit op HTTP in plaats van HTTPS.
- **`apt-get` faalt in de container** → controleer `DNS_SERVER` en de gateway.

## Wat het script niet doet

- Geen port-forward of routerwijziging: de site is bedoeld voor je LAN.
- Geen DHCP-reservering; vraag die aan in je router als je het adres vast wilt houden.
- Geen automatische updates van de app; gebruik `update-site.sh`.
