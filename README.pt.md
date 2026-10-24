[English](README.en.md) | [Français](README.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md) | **Português** | [Nederlands](README.nl.md) | [Русский](README.ru.md) | [中文](README.zh.md) | [العربية](README.ar.md)

# ToutWAF Backup - binários (ramo `toutwaf-backup`)

Este ramo contém apenas **binários assinados** do ToutWAF Backup (servidor e cliente de cópias, um único executável `toutwaf-backup`) e os respetivos instaladores. Aqui não há código-fonte. Os instaladores e a linha de comandos falam dez idiomas; as traduções foram escritas por uma máquina e não foram revistas por falantes nativos.

## Versão disponível

| Versão | Canal | Compilação | Publicada |
|---|---|---|---|
| `0.1.2` | dev | `8efe447af258` | 2026-10-24 |

## Instalar

Ponha o **cliente** em cada máquina que quer proteger; o **servidor** tem de correr numa **máquina diferente** da do ToutWAF (uma cópia guardada na máquina que protege não sobrevive à perda dessa máquina: o instalador recusa o papel de servidor junto ao ToutWAF).

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

Espelho se o primeiro anfitrião estiver inacessível: `https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup` (`--base-url` ou `TOUTWAF_BACKUP_BASE_URL` para escolher).

Idioma do instalador: `--lang fr` (ou `--es`, `--de` ...; `-Lang fr` no Windows), caso contrário o idioma do seu sistema, num terminal UTF-8.

## Verificar uma versão

`releases/<versão>/SHA256SUMS` lista os SHA-256 dos arquivos; `SHA256SUMS.sig` é a assinatura Ed25519 (base64) desse ficheiro. A chave pública é `release.pub` (a mesma do produto ToutWAF: `ebd2a20ce5a5650f`). Os instaladores verificam a assinatura e depois o hash antes de instalar seja o que for.

```sh
V=0.1.2
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## Conteúdo

`install.sh`, `install.ps1`, `channel.json` (o ponteiro «última versão»), `release.pub`, `CHANGELOG.md`, `LICENSE`, `releases/<versão>/`.
