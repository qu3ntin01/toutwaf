[English](README.en.md) | **Français** | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [Nederlands](README.nl.md) | [Русский](README.ru.md) | [中文](README.zh.md) | [العربية](README.ar.md)

# ToutWAF Backup - binaires (branche `toutwaf-backup`)

Cette branche ne contient que des **binaires signés** de ToutWAF Backup (serveur et client de sauvegarde, un seul exécutable `toutwaf-backup`) et leurs installateurs. Le code source n'y est pas. Les installateurs et la ligne de commande parlent dix langues ; les traductions sont rédigées par une machine et n'ont pas été relues par des locuteurs natifs.

## Version disponible

| Version | Canal | Build | Publiée |
|---|---|---|---|
| `0.1.1` | dev | `0270440dc7e0` | 2026-10-24 |

## Installer

Le **client** se met sur chaque machine à protéger ; le **serveur** doit tourner sur une **autre machine** que ToutWAF (une sauvegarde stockée sur la machine qu'elle protège ne survit pas à la perte de cette machine : l'installateur refuse le rôle serveur à côté de ToutWAF).

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

Miroir si le premier serveur est injoignable : `https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup` (`--base-url` ou `TOUTWAF_BACKUP_BASE_URL` pour choisir).

Langue de l'installateur : `--lang fr` (ou `--es`, `--de` ... ; `-Lang fr` sous Windows), sinon la langue de votre système, dans un terminal UTF-8.

## Vérifier une version

`releases/<version>/SHA256SUMS` liste les empreintes SHA-256 des archives ; `SHA256SUMS.sig` est la signature Ed25519 (base64) de ce fichier. La clé publique est `release.pub` (la même que celle du produit ToutWAF : `ebd2a20ce5a5650f`). Les installateurs vérifient la signature puis l'empreinte avant d'installer quoi que ce soit.

```sh
V=0.1.1
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## Contenu

`install.sh`, `install.ps1`, `channel.json` (pointeur « dernière version »), `release.pub`, `CHANGELOG.md`, `LICENSE`, `releases/<version>/`.
