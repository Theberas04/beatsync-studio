# BeatSync Studio

Een single-file web-app (één `index.html`) waarmee je video's laat meelopen met de beat van audio.
Alles draait lokaal in je browser: er worden geen bestanden geüpload.

## Functies

- Meerdere lokale video's kiezen en er tussen wisselen.
- Audiobron kiezen via een dropdown:
  - lokaal audiobestand
  - directe audio-URL
  - ingebouwde browser / radiowebsites (o.a. radiozenders.fm en nederland.fm)
  - audio van een ander browsertabblad delen
- Live VU-meter met piek- en RMS-waarde in dBFS.
- Live spectrum-analyzer (EQ-weergave).
- BPM-schatting met adaptieve beat-detectie, plus tap-tempo.
- Videosnelheid aanpassen op basis van BPM, met timing-offset en automatische modus.

## Gebruik

1. Open `index.html` in Chrome of Edge.
2. Kies een of meer video's en selecteer de video die je wilt afspelen.
3. Kies onder **Audiobron** de bron die je wilt gebruiken.
4. Stel zo nodig BPM, offset en snelheid in.

Voor het delen van tabblad- of schermaudio moet je in de browserdialoog het juiste
tabblad kiezen en **audio delen** aanvinken. Werkt het beste in Chrome of Edge.

## Beperkingen

- BPM-detectie is een schatting; bij complexe muziek kan er een halve of dubbele
  beat worden geteld. Gebruik de offset om bij te sturen.
- De spectrum-analyzer toont frequenties maar verandert het geluid niet.
- Bronnen die geen direct audiobestand aanleveren (zoals beveiligde
  streamingdiensten) kunnen niet rechtstreeks worden uitgelezen; gebruik daar de
  optie om tabbladaudio te delen, mits de browser dat toestaat.
- Van YouTube-video's kan de audio niet door de pagina worden geanalyseerd. In deze
  versie is YouTube-ondersteuning daarom verwijderd.

## Licentie

Geen licentiebestand toegevoegd; het project is privé in beheer.
