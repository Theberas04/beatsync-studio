<div align="center">

# BeatSync Studio

**Video's laten meelopen met de beat — volledig in de browser.**

Meerdere video's, een eigen audiobron, live BPM-detectie en tempo-correctie in één
HTML-bestand. Niets wordt geüpload: alles draait op het apparaat van de gebruiker.

[![CI](https://github.com/Theberas04/beatsync-studio/actions/workflows/validate.yml/badge.svg)](https://github.com/Theberas04/beatsync-studio/actions/workflows/validate.yml)
[![Live](https://img.shields.io/badge/live-theberas04.github.io%2Fbeatsync--studio-1f6feb)](https://theberas04.github.io/beatsync-studio/)
[![Taal](https://img.shields.io/badge/interface-Nederlands-ffc629)](https://theberas04.github.io/beatsync-studio/)

[**Open de live-versie →**](https://theberas04.github.io/beatsync-studio/)

[![BeatSync Studio](docs/screenshots/hero.jpg)](https://theberas04.github.io/beatsync-studio/)

</div>

---

## Wat het doet

Je laadt een of meer video's, kiest een audiobron, en BeatSync meet het tempo van die
audio. Met één klik loopt de video mee: de afspeelsnelheid wordt op de BPM gezet, met een
offset in milliseconden om het beeld precies op de tel te leggen.

| | |
|---|---|
| ![Video via een URL](docs/screenshots/video-via-url.jpg) | ![Meerdere bronnen in één lijst](docs/screenshots/keuzelijst.jpg) |
| **Video via een URL** — plak een directe link naar een MP4/WebM; hij komt naast je lokale bestanden in de lijst. | **Alles in één keuzelijst** — de meegeleverde clip (🎬), eigen bestanden en URL's (🔗) door elkaar. |

### De hele app

[![Volledige app](docs/screenshots/app-volledig.jpg)](https://theberas04.github.io/beatsync-studio/)

## Functies

- **Video's**: meerdere lokale bestanden kiezen, een video-URL plakken, of de meegeleverde clip gebruiken — alles in één keuzelijst.
- **Audiobron** via een dropdown:
  - lokaal audiobestand
  - directe audio-URL
  - ingebouwde browser met radiowebsites (o.a. radiozenders.fm en nederland.fm)
  - **Descent-links** van 11 Nederlandse zenders (Qmusic, KINK, JOE, NPO Radio 2, Radio 10, Sky Radio, Veronica, SLAM!, NPO Radio 2 Soul & Jazz) — direct te kiezen in de dropdown
  - audio van een ander browsertabblad delen
- **Live VU-meter** met piek- en RMS-waarde in dBFS.
- **Live spectrum-analyzer** (EQ-weergave).
- **BPM-schatting** met adaptieve beat-detectie, plus tap-tempo.
- **Tempo-correctie**: videosnelheid op basis van BPM, met timing-offset en automatische modus.

## Gebruik

1. Open de [live-versie](https://theberas04.github.io/beatsync-studio/) of `index.html` in Chrome of Edge.
2. Kies een of meer video's, of plak een directe video-URL en klik op **URL laden**. Alles komt in de keuzelijst; wisselen kan altijd.
3. Kies onder **Audiobron** de bron die je wilt gebruiken.
4. Stel zo nodig BPM, offset en snelheid in.

Voor het delen van tabblad- of schermaudio moet je in de browserdialoog het juiste
tabblad kiezen en **audio delen** aanvinken. Werkt het beste in Chrome of Edge.

### Meegeleverde clip

`media/nep-beatclip.mp4` hoort bij de site en staat bij het openen al in de keuzelijst
(label 🎬). Op de container hoort hij in `/var/www/beatsync/media/` te staan;
`update-from-github.sh` zet hem daar samen met `index.html` neer.

![Meegeleverde clip in de keuzelijst](docs/screenshots/video-meegeleverd.jpg)

### Video via een URL

Plak een directe link naar een videobestand (MP4, WebM, Ogg, MOV) in het URL-veld en klik
op **URL laden**.

- Werkt: links die direct een mediabestand opleveren, ook als de host geen CORS-headers
  stuurt — afspelen vereist geen CORS.
- Werkt ook: meerdere URL's naast lokale bestanden; ze staan samen in de keuzelijst.
- Werkt niet: een YouTube-, Vimeo- of andere **webpagina**-link. Dat is geen videobestand,
  dus de browser kan hem niet laden — de app meldt dat dan ook. Een link achter een login
  of met een 403 geeft hetzelfde probleem.

## Beperkingen

- BPM-detectie is een schatting; bij complexe muziek kan er een halve of dubbele beat
  worden geteld. Gebruik de offset om bij te sturen.
- De spectrum-analyzer toont frequenties maar verandert het geluid niet.
- Bronnen zonder direct audiobestand (beveiligde streamingdiensten) kunnen niet
  rechtstreeks worden uitgelezen; gebruik daar de optie om tabbladaudio te delen, mits de
  browser dat toestaat.
- Van YouTube-video's kan de audio niet door de pagina worden geanalyseerd; daarom is
  YouTube-ondersteuning in deze versie verwijderd.

## Installeren op Proxmox met één commando

Op de Proxmox-host als root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/install.sh)
```

Het script maakt een Debian LXC-container (DHCP), installeert nginx en zet de site klaar.
Meer opties en probleemoplossing: [`deploy/proxmox/README.md`](deploy/proxmox/README.md).

### Bestaande container bijwerken

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/beatsync-studio/main/deploy/proxmox/update-from-github.sh) 103
```

Haalt `index.html` én alle bestanden uit `media/` op, maakt een backup en controleert per
bestand de sha256. Tweede keer draaien verandert niets.

## Publiek bereikbaar (Cloudflare Tunnel)

Zet de site op een hostname zonder open poorten:

```bash
./add-cloudflare-tunnel.sh <container-id>
```

Diagnose en probleemoplossing (redirect-lus, certificaatdekking, origin-instellingen):
[`deploy/proxmox/README.md`](deploy/proxmox/README.md).

## Projectstructuur

```
index.html                     de hele app: HTML, CSS en JS in één bestand
media/nep-beatclip.mp4         meegeleverde clip
docs/screenshots/              beelden voor deze README
deploy/proxmox/install.sh      one-liner installatie
deploy/proxmox/update-from-github.sh   site + media bijwerken in een bestaande container
deploy/proxmox/check-tunnel.sh diagnose van de Cloudflare-route
deploy/proxmox/fix-loop.sh     redirect-lus achter een tunnel repareren
.github/workflows/validate.yml CI: JS-syntax, HTML-controles, shellscripts
```

## Licentie

Geen licentiebestand toegevoegd; het project is in eigen beheer.
