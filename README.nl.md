[English](README.en.md) | [Français](README.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md) | [Português](README.pt.md) | **Nederlands** | [Русский](README.ru.md) | [中文](README.zh.md) | [العربية](README.ar.md)

# ToutWAF Backup - programma's (branch `toutwaf-backup`)

Deze branch bevat alleen **ondertekende programma's** van ToutWAF Backup (back-upserver en -client, één uitvoerbaar bestand `toutwaf-backup`) en hun installatieprogramma's. Er is hier geen broncode. De installatieprogramma's en de opdrachtregel spreken tien talen; de vertalingen zijn door een machine geschreven en niet door moedertaalsprekers nagelezen.

## Beschikbare versie

| Versie | Kanaal | Build | Gepubliceerd |
|---|---|---|---|
| `0.1.1` | dev | `0270440dc7e0` | 2026-10-24 |

## Installeren

Zet de **client** op elke machine die u wilt beschermen; de **server** moet op een **andere machine** dan ToutWAF draaien (een back-up op de machine die hij beschermt overleeft het verlies van die machine niet: het installatieprogramma weigert de serverrol naast ToutWAF).

```sh
# Linux: client
curl -fsSL https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/toutwaf-backup/install.sh | sudo bash -s -- --role client
# Linux: server (on a dedicated machine)
curl -fsSL https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/toutwaf-backup/install.sh | sudo bash -s -- --role server --datastore main=/srv/backups/main --start
```

```powershell
# Windows: client (read the script before running it)
irm https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/toutwaf-backup/install.ps1 -OutFile install.ps1
.\install.ps1 -Role client
```

Spiegel als de eerste host onbereikbaar is: `https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup` (kies met `--base-url` of `TOUTWAF_BACKUP_BASE_URL`).

Taal van het installatieprogramma: `--lang fr` (of `--es`, `--de` ...; `-Lang fr` onder Windows), anders de taal van uw systeem, in een UTF-8-terminal.

## Een release controleren

`releases/<versie>/SHA256SUMS` somt de SHA-256-waarden van de archieven op; `SHA256SUMS.sig` is de Ed25519-handtekening (base64) van dat bestand. De publieke sleutel is `release.pub` (dezelfde als die van het product ToutWAF: `ebd2a20ce5a5650f`). De installatieprogramma's controleren de handtekening en daarna de hash voordat ze iets installeren.

```sh
V=0.1.1
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## Inhoud

`install.sh`, `install.ps1`, `channel.json` (de verwijzing naar de nieuwste versie), `release.pub`, `CHANGELOG.md`, `LICENSE`, `releases/<versie>/`.
