**English** | [Français](README.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [Nederlands](README.nl.md) | [Русский](README.ru.md) | [中文](README.zh.md) | [العربية](README.ar.md)

# ToutWAF Backup - binaries (branch `toutwaf-backup`)

This branch holds only **signed binaries** of ToutWAF Backup (backup server and client, one `toutwaf-backup` executable) and their installers. There is no source code here. The installers and the command line speak ten languages; the translations are machine-written and not reviewed by native speakers.

## Available version

| Version | Channel | Build | Published |
|---|---|---|---|
| `0.1.2` | dev | `8efe447af258` | 2026-10-24 |

## Install

Put the **client** on every machine you want to protect; the **server** must run on a **different machine** than ToutWAF (a backup stored on the machine it protects does not survive the loss of that machine: the installer refuses the server role next to ToutWAF).

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

Mirror if the first host is unreachable: `https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup` (`--base-url` or `TOUTWAF_BACKUP_BASE_URL` to choose).

The installer first updates the system packages (`--no-system-update` to skip it), installs what it needs, opens the server's port in firewalld or ufw when one is active (`--no-firewall`, `--firewall-from CIDR`), and installs the update manager: `toutwaf-backup-update status | check | apply | rollback | auto on|off | channel stable|dev` (a daily timer checks; it installs by itself only with `auto on`). Tested on Debian 12/13, Ubuntu 22.04/24.04/26.04 and AlmaLinux/Rocky/RHEL 9/10.

Language of the installer: `--lang fr` (or `--es`, `--de` ...; `-Lang fr` on Windows), otherwise the language of your system, in a UTF-8 terminal.

## Verify a release

`releases/<version>/SHA256SUMS` lists the SHA-256 of the archives; `SHA256SUMS.sig` is the Ed25519 signature (base64) of that file. The public key is `release.pub` (the same key as the ToutWAF product: `ebd2a20ce5a5650f`). The installers verify the signature, then the hash, before installing anything.

```sh
V=0.1.2
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## Contents

`install.sh`, `install.ps1`, `channel.json` (the "latest" pointer), `release.pub`, `CHANGELOG.md`, `LICENSE`, `releases/<version>/`.
