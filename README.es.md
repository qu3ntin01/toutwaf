[English](README.en.md) | [Français](README.md) | **Español** | [Deutsch](README.de.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [Nederlands](README.nl.md) | [Русский](README.ru.md) | [中文](README.zh.md) | [العربية](README.ar.md)

# ToutWAF Backup - binarios (rama `toutwaf-backup`)

Esta rama contiene solo **binarios firmados** de ToutWAF Backup (servidor y cliente de copias, un único ejecutable `toutwaf-backup`) y sus instaladores. Aquí no hay código fuente. Los instaladores y la línea de comandos hablan diez idiomas; las traducciones las ha escrito una máquina y no las han revisado hablantes nativos.

## Versión disponible

| Versión | Canal | Compilación | Publicada |
|---|---|---|---|
| `0.1.2` | dev | `8efe447af258` | 2026-10-24 |

## Instalar

Ponga el **cliente** en cada máquina que quiera proteger; el **servidor** debe ejecutarse en una **máquina distinta** de la de ToutWAF (una copia guardada en la máquina que protege no sobrevive a la pérdida de esa máquina: el instalador rechaza el rol de servidor junto a ToutWAF).

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

Réplica si el primer servidor no es accesible: `https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup` (`--base-url` o `TOUTWAF_BACKUP_BASE_URL` para elegir).

Idioma del instalador: `--lang fr` (o `--es`, `--de` ...; `-Lang fr` en Windows); si no, el idioma de su sistema, en un terminal UTF-8.

## Verificar una versión

`releases/<version>/SHA256SUMS` lista los SHA-256 de los archivos; `SHA256SUMS.sig` es la firma Ed25519 (base64) de ese archivo. La clave pública es `release.pub` (la misma que la del producto ToutWAF: `ebd2a20ce5a5650f`). Los instaladores verifican la firma y luego el hash antes de instalar nada.

```sh
V=0.1.2
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## Contenido

`install.sh`, `install.ps1`, `channel.json` (el puntero «última versión»), `release.pub`, `CHANGELOG.md`, `LICENSE`, `releases/<versión>/`.
