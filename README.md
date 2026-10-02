# ToutWAF - stable channel

ToutWAF is a self-hosted web application firewall and reverse proxy (data plane `toutwaf-dp`, control plane `toutwaf-cp` with its web console, CLI `toutwafctl`).

This repository publishes **binaries and installers only**; it contains no source code. This `main` branch is the stable channel. Pre-releases are on the `dev` branch.

**Current version: `0.2.0-dev.1`** (released 2026-10-02T14:59:13Z)

## Install

Linux x86_64 (amd64). Validated with these exact binaries on AlmaLinux 10, Rocky Linux 9 and Debian 12; AlmaLinux 9 and Ubuntu 24.04 passed earlier test runs on a previous build. Other distributions and arm64 are not tested and no arm64 package is published yet:

```sh
curl -fsSL https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.sh | sudo bash
```

Windows x64 (PowerShell as administrator). The Windows installer has not been validated on a real Windows host yet:

```powershell
irm https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.ps1 | iex
```

The installer of this branch defaults to the stable channel. Options (`--channel`, `--version`, `--component`, `--help`) are documented by `install.sh --help`.

## Assets of 0.2.0-dev.1

| Asset | OS | Arch | Size | SHA-256 |
|---|---|---|---:|---|
| `toutwaf-linux-amd64.tar.gz` | linux | amd64 | 28.0 MiB | `5be95f34a6a5e66537e806d0b04c6d95c8f0941cc59c0ce2461277cc9c9620d9` |
| `toutwaf-windows-amd64.zip` | windows | amd64 | 28.6 MiB | `d5b6666e04a15c2eb7f9ce105c120a3b9b068a33ff1ea7b04317a3521f19a780` |

Targets not built for this release:

- `linux-arm64`: rust target aarch64-unknown-linux-gnu not installed (rustup target add aarch64-unknown-linux-gnu)

## Versions

| Version | Released | Status | Directory |
|---|---|---|---|
| `0.2.0-dev.1` | 2026-10-02T14:59:13Z | **current** | `releases/0.2.0-dev.1/` |

## Verify a download

Every release directory has a `SHA256SUMS` file (`sha256sum -c` compatible) and `channel.json` repeats the hashes of the current release:

```sh
cd releases/0.2.0-dev.1 && sha256sum -c SHA256SUMS --ignore-missing
```

These releases are not signed; rely on the SHA-256 checksums above.

## Layout

`channel.json` is the pointer to the latest release of the channel, `releases/<version>/` holds the archives, `SHA256SUMS`, `manifest.json`. See `CHANGELOG.md` for release notes.

## License

Proprietary: see `LICENSE`.
