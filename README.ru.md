[English](README.en.md) | [Français](README.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [Nederlands](README.nl.md) | **Русский** | [中文](README.zh.md) | [العربية](README.ar.md)

# ToutWAF Backup - бинарные файлы (ветка `toutwaf-backup`)

В этой ветке находятся только **подписанные бинарные файлы** ToutWAF Backup (сервер и клиент резервного копирования, один исполняемый файл `toutwaf-backup`) и их установщики. Исходного кода здесь нет. Установщики и командная строка говорят на десяти языках; переводы написаны машиной и не проверялись носителями языка.

## Доступная версия

| Версия | Канал | Сборка | Опубликована |
|---|---|---|---|
| `0.1.1` | dev | `0270440dc7e0` | 2026-10-24 |

## Установка

Ставьте **клиент** на каждую защищаемую машину; **сервер** должен работать на **другой машине**, чем ToutWAF (копия, хранящаяся на защищаемой машине, не переживёт её потерю: установщик отказывается ставить роль сервера рядом с ToutWAF).

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

Зеркало, если первый узел недоступен: `https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup` (выбор через `--base-url` или `TOUTWAF_BACKUP_BASE_URL`).

Язык установщика: `--lang fr` (или `--es`, `--de` ...; в Windows `-Lang fr`), иначе язык вашей системы, в терминале UTF-8.

## Проверка релиза

`releases/<версия>/SHA256SUMS` перечисляет SHA-256 архивов; `SHA256SUMS.sig` — подпись Ed25519 (base64) этого файла. Открытый ключ — `release.pub` (тот же, что у продукта ToutWAF: `ebd2a20ce5a5650f`). Установщики проверяют подпись, затем хэш, прежде чем что-либо устанавливать.

```sh
V=0.1.1
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## Содержимое

`install.sh`, `install.ps1`, `channel.json` (указатель «последняя версия»), `release.pub`, `CHANGELOG.md`, `LICENSE`, `releases/<версия>/`.
