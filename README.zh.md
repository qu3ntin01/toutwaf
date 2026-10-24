[English](README.en.md) | [Français](README.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [Nederlands](README.nl.md) | [Русский](README.ru.md) | **中文** | [العربية](README.ar.md)

# ToutWAF Backup - 二进制文件（分支 `toutwaf-backup`）

此分支只包含 ToutWAF Backup 的**已签名二进制文件**（备份服务器和客户端，单个可执行文件 `toutwaf-backup`）及其安装程序。这里没有源代码。安装程序和命令行支持十种语言；译文由机器撰写，未经母语人士审校。

## 可用版本

| 版本 | 渠道 | 构建 | 发布日期 |
|---|---|---|---|
| `0.1.1` | dev | `0270440dc7e0` | 2026-10-24 |

## 安装

在每台要保护的机器上安装**客户端**；**服务器**必须运行在与 ToutWAF **不同的机器**上（存放在被保护机器本身的备份，无法在该机器丢失时幸存：安装程序会拒绝在 ToutWAF 旁边安装服务器角色）。

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

如果第一个主机无法访问，可使用镜像：`https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup`（用 `--base-url` 或 `TOUTWAF_BACKUP_BASE_URL` 选择）。

安装程序语言：`--lang fr`（或 `--es`、`--de` ...；Windows 上用 `-Lang fr`），否则使用系统语言（需 UTF-8 终端）。

## 验证发布版

`releases/<版本>/SHA256SUMS` 列出各压缩包的 SHA-256；`SHA256SUMS.sig` 是该文件的 Ed25519 签名（base64）。公钥是 `release.pub`（与 ToutWAF 产品相同：`ebd2a20ce5a5650f`）。安装程序在安装任何内容之前，先验证签名，再验证哈希。

```sh
V=0.1.1
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## 内容

`install.sh`、`install.ps1`、`channel.json`（“最新版本”指针）、`release.pub`、`CHANGELOG.md`、`LICENSE`、`releases/<版本>/`。
