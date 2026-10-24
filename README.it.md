[English](README.en.md) | [Français](README.md) | [Español](README.es.md) | [Deutsch](README.de.md) | **Italiano** | [Português](README.pt.md) | [Nederlands](README.nl.md) | [Русский](README.ru.md) | [中文](README.zh.md) | [العربية](README.ar.md)

# ToutWAF Backup - binari (ramo `toutwaf-backup`)

Questo ramo contiene solo **binari firmati** di ToutWAF Backup (server e client di backup, un unico eseguibile `toutwaf-backup`) e i loro installer. Qui non c'è codice sorgente. Gli installer e la riga di comando parlano dieci lingue; le traduzioni sono scritte da una macchina e non riviste da madrelingua.

## Versione disponibile

| Versione | Canale | Build | Pubblicata |
|---|---|---|---|
| `0.1.2` | dev | `8efe447af258` | 2026-10-24 |

## Installare

Metti il **client** su ogni macchina da proteggere; il **server** deve girare su una **macchina diversa** da quella di ToutWAF (un backup archiviato sulla macchina che protegge non sopravvive alla perdita di quella macchina: l'installer rifiuta il ruolo server accanto a ToutWAF).

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

Mirror se il primo host è irraggiungibile: `https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup` (`--base-url` o `TOUTWAF_BACKUP_BASE_URL` per sceglierlo).

Lingua dell'installer: `--lang fr` (o `--es`, `--de` ...; `-Lang fr` su Windows), altrimenti la lingua del tuo sistema, in un terminale UTF-8.

## Verificare una release

`releases/<versione>/SHA256SUMS` elenca gli SHA-256 degli archivi; `SHA256SUMS.sig` è la firma Ed25519 (base64) di quel file. La chiave pubblica è `release.pub` (la stessa del prodotto ToutWAF: `ebd2a20ce5a5650f`). Gli installer verificano la firma, poi l'hash, prima di installare qualsiasi cosa.

```sh
V=0.1.2
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## Contenuto

`install.sh`, `install.ps1`, `channel.json` (il puntatore «ultima versione»), `release.pub`, `CHANGELOG.md`, `LICENSE`, `releases/<versione>/`.
