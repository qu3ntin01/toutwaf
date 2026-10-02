# ToutWAF - stable channel

ToutWAF is a self-hosted web application firewall and reverse proxy (data plane `toutwaf-dp`, control plane `toutwaf-cp` with its web console, CLI `toutwafctl`).

This repository publishes **binaries and installers only**; it contains no source code. This `main` branch is the stable channel. Pre-releases are on the `dev` branch.

> **No stable release has been published yet.** The installers will report this until the first release is available.

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

## Verify a download

Every release directory has a `SHA256SUMS` file (`sha256sum -c` compatible) and `channel.json` repeats the hashes of the current release:

```sh
cd releases/<version> && sha256sum -c SHA256SUMS --ignore-missing
```

These releases are not signed; rely on the SHA-256 checksums above.

## Layout

`channel.json` is the pointer to the latest release of the channel, `releases/<version>/` holds the archives, `SHA256SUMS`, `manifest.json`. See `CHANGELOG.md` for release notes.

## License

Proprietary: see `LICENSE`.
