# ToutWAF Backup - binaries (branch `toutwaf-backup`)

This branch holds only **signed binaries** of ToutWAF Backup (backup server and client, one `toutwaf-backup` executable) and their installers. There is no source code here.

Francais: [README.md](README.md)

## Available version

| Version | Channel | Build | Published |
|---|---|---|---|
| `0.1.0-dev` | dev | `8965b7890a92` | 2026-10-23 |

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

## Verify a release

`releases/<version>/SHA256SUMS` lists the SHA-256 of the archives; `SHA256SUMS.sig` is the Ed25519 signature (base64) of that file. The public key is `release.pub` (the same key as the ToutWAF product: `ebd2a20ce5a5650f`). The installers verify the signature, then the hash, before installing anything.

```sh
V=0.1.0-dev
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## Contents

`install.sh`, `install.ps1`, `channel.json` (the "latest" pointer), `release.pub`, `CHANGELOG.md`, `LICENSE`, `releases/<version>/`.
