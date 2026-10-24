[English](README.en.md) | [Français](README.md) | [Español](README.es.md) | **Deutsch** | [Italiano](README.it.md) | [Português](README.pt.md) | [Nederlands](README.nl.md) | [Русский](README.ru.md) | [中文](README.zh.md) | [العربية](README.ar.md)

# ToutWAF Backup - Programme (Branch `toutwaf-backup`)

Dieser Branch enthält nur **signierte Programme** von ToutWAF Backup (Backup-Server und -Client, eine einzige Programmdatei `toutwaf-backup`) und ihre Installer. Quellcode gibt es hier nicht. Die Installer und die Kommandozeile sprechen zehn Sprachen; die Übersetzungen wurden maschinell erstellt und nicht von Muttersprachlern geprüft.

## Verfügbare Version

| Version | Kanal | Build | Veröffentlicht |
|---|---|---|---|
| `0.1.2` | dev | `8efe447af258` | 2026-10-24 |

## Installieren

Installieren Sie den **Client** auf jedem zu schützenden Rechner; der **Server** muss auf einem **anderen Rechner** als ToutWAF laufen (eine Sicherung auf dem Rechner, den sie schützt, übersteht dessen Verlust nicht: Der Installer lehnt die Server-Rolle neben ToutWAF ab).

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

Spiegel, falls der erste Host nicht erreichbar ist: `https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup` (mit `--base-url` oder `TOUTWAF_BACKUP_BASE_URL` wählbar).

Sprache des Installers: `--lang fr` (oder `--es`, `--de` ...; unter Windows `-Lang fr`), sonst die Sprache Ihres Systems, in einem UTF-8-Terminal.

## Eine Version prüfen

`releases/<Version>/SHA256SUMS` listet die SHA-256-Werte der Archive auf; `SHA256SUMS.sig` ist die Ed25519-Signatur (Base64) dieser Datei. Der öffentliche Schlüssel ist `release.pub` (derselbe wie beim Produkt ToutWAF: `ebd2a20ce5a5650f`). Die Installer prüfen die Signatur, dann den Hash, bevor sie irgendetwas installieren.

```sh
V=0.1.2
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## Inhalt

`install.sh`, `install.ps1`, `channel.json` (der Zeiger „neueste Version“), `release.pub`, `CHANGELOG.md`, `LICENSE`, `releases/<Version>/`.
