<div align="center">

# ToutWAF

**Self-hosted security platform: network firewall, web application firewall (WAF) and web application and API protection (WAAP), with a web console in 10 languages.**

Firewall · WAF · WAAP · API protection · anti-bot · anti-DDoS · multi-node resilience · reverse proxy · VPN · encrypted backups

[Install](#installation) · [Features](#features) · [Screenshots](#screenshots) · [Architecture](#architecture) · [First start](#first-start) · [Français](README.md)

**Version 0.7.0** · build `a7e4c64561ed` · channel **stable** · 2026-11-21

</div>

![ToutWAF dashboard](screenshots/tableau-de-bord.png)

---

## What is ToutWAF?

ToutWAF sits **in front of your websites and APIs** and inspects every request before it reaches your application: SQL injection, XSS, command execution, malicious bots, volumetric attacks, data leaks in responses... Clean requests go through, the others are blocked, and every decision is **explained** in the console with the rule that fired.

ToutWAF combines three protections: a **network firewall** (interfaces, zones, NAT, routes, VPN) that filters traffic at machine level; a **WAF** that reads every web request; and a **WAAP** that adds API protection (Observation / Balanced / Strict profiles, OpenAPI import), bot management and resistance to volumetric attacks. It replaces neither a dedicated border firewall nor an upstream anti-DDoS service.

It installs on **your own server** (Linux or Windows), with no cloud service: your traffic data stays with you.

> **Stable channel.** This branch receives **only a version of which everything was tested**: every system, every package, end to end, no experimental function. Nothing else arrives here; only the latest stable version stays. The development version is on the [`dev`](https://github.com/qu3ntin01/toutwaf/tree/dev) branch.

> This repository publishes ToutWAF **installers and binaries only**. It contains no source code.

## Features

**Web application protection**
- Detection of SQL and NoSQL injection, XSS, command injection, file inclusion and path traversal, SSRF, XXE, template injection, deserialization, Log4Shell and Spring4Shell, CRLF, request smuggling, dangerous file uploads.
- Rule engine compatible with the ModSecurity language (SecLang), paranoia levels 1 to 4, anomaly scoring, virtual patches for CVEs, custom rules in a readable language with a visual editor.
- **Detect first, block later**: see what would be blocked, create narrow exceptions in one click, simulate a rule before enabling it, roll out gradually (1% / 10% / 100%), and roll back in one click.

**API protection**
- OpenAPI and GraphQL validation, JWT checks, API keys and quotas, per-consumer rate limiting, detection of data leaks (card numbers, IBAN, secret keys) in responses.

**Bots and volumetric attacks**
- Bot score, invisible JavaScript challenge (proof of work), built-in CAPTCHA, TLS fingerprints (JA3/JA4), verified legitimate crawlers, AI-crawler policy.
- Multi-key rate limiting, progressive automatic bans, "I'm under attack" mode, protection against slow connections and HTTP/2 abuse.

**Access control**
- IP and network lists, countries and ASNs, IP reputation, Tor/VPN/hosting detection, restriction of admin areas.

**Reverse proxy**
- TLS 1.2/1.3, HTTP/2, WebSocket, load balancing, health checks, cache, compression, automatic certificates (Let's Encrypt / ZeroSSL).

**Administration console**
- **10 languages** (French, English, Spanish, German, Italian, Portuguese, Dutch, Russian, Chinese, Arabic); **7 themes**, a custom accent colour, a default *Aurora* look (light, blue accent, Plus Jakarta Sans font) and a menu whose sections start folded.
- Live events with search, an explanation of every decision, a "false positive" button, policy versions with rollback, roles and permissions, two-factor authentication, SSO, audit log, REST API.
- Secure access: secret link, one-time setup link, changeable account and password.
- **Product updates from the console**: pick the `stable` or `dev` channel, get an instant notice (top-bar pill, banner, toast) as soon as a version is published (checked about every 5 minutes), read the release notes and click **Update now** to follow a live progress; if the new version does not start, the previous one is restored automatically.
- **First-run wizard** you can skip, with help next to the origin URL field and a **stack detection** that shows the layers found (web server, language, framework, CMS...), a confidence level and the evidence behind each guess.

**Network firewall and VPN** (modules on by default)
- Network interfaces (VLAN, bridge, bond, address, MTU) with a trial and automatic rollback, kept across reboots; zones, NAT, static routes, DHCP and DNS, captive portal, gateway groups, URL and country aliases; open ports on this server and on all nodes in one click.
- IPsec, L2TP/IPsec and SSL VPN. What was tried on a real kernel and what was not is detailed in the documentation.

**Attack resilience and cluster**
- Five independent solutions, chosen by the administrator, with advantages and drawbacks written in the console: reserve nodes, load shedding through DNS, layer-7 escalation, volumetric help (Cloudflare only), overflow forwarding between nodes (optional, off by default). General kill switch and "undo everything".
- Node zones, nodes x servers matrix, per-site fallback between zones; a bounded, audited relay to a server only a node can see.
- **Architecture** page: the network and software stack of your installation, simple or detailed down to the site.

**Operations**
- **Encrypted backups** with off-site copies (S3-compatible, SFTP, WebDAV), retention and automatic restore tests.
- **Backup and restore area** (manual backup, restore points, fresh-server restore with `install.sh --restore`): available only when ToutWAF Backup is activated.
- **Mail gateway**: optional automatic updates with a stored, encrypted access; **free public certificate for the console** with the same key (pinned fingerprints stay valid); node updates from the console with live progress.
- Alerts and integrations (SIEM, Slack, Teams, e-mail, PagerDuty...), Prometheus metrics, multi-organisation.
- **Host firewall**: on Linux the installer opens the ports ToutWAF needs when firewalld or ufw is active, and **Settings → Firewall** shows the state of each port and opens the missing ones.

## Screenshots

| | |
|---|---|
| ![Events](screenshots/evenements.png) **Events**: every request, explained | ![Sites](screenshots/sites.png) **Sites**: protection and score per site |
| ![Rules](screenshots/regles.png) **Rules**: modes, exceptions, simulation | ![Backups](screenshots/sauvegardes.png) **Backups**: encrypted, off-site copies |
| ![Cluster](screenshots/cluster.png) **Cluster**: your servers, security score and alerts | ![Server](screenshots/cluster-serveur.png) **Server dashboard**: live resources, fixes, terminal |
| ![Diagnostics](screenshots/diagnostics.png) **Setup assistant**: checks ports 80/443, certificates and the data plane | ![Definitions](screenshots/definitions.png) **Definitions**: 19 sources updated automatically every hour |

**Fully customisable: several themes, light or dark mode, your own accent colour** (Settings → Appearance). The default look is *Aurora* in light mode with a blue accent:

![Theme picker](screenshots/themes.png)

| Aurora (dark) | Nordic | Executive |
|---|---|---|
| ![Aurora](screenshots/theme-aurora.png) | ![Nordic](screenshots/theme-nordic.png) | ![Executive](screenshots/theme-executive.png) |

| Obsidian | Ember |
|---|---|
| ![Obsidian](screenshots/theme-obsidian.png) | ![Ember](screenshots/theme-ember.png) |

> Screenshots taken with demonstration data (the console shown in French).

## Architecture

```mermaid
flowchart LR
    V[Visitors] -->|HTTPS 80 / 443| DP["<b>toutwaf-dp</b><br/>reverse proxy + WAF engine"]
    DP -->|clean requests| APP[(Your sites and APIs)]
    DP <-->|policy, events| CP["<b>toutwaf-cp</b><br/>console + API + storage"]
    ADM[Administrator] -->|"https://IP:9443/secret-path/"| CP
```

| Component | Role |
|---|---|
| **`toutwaf-dp`** (data plane) | Receives the traffic, inspects every request and response, applies the policy. It **keeps protecting even if the console is down** (last policy cached). |
| **`toutwaf-cp`** (control plane) | Web console, REST API, versioned policies, accounts and permissions, events, backups, certificates. |
| **`toutwafctl`** | Command line: sites, policies, bans, backups, diagnostics. |

One server is enough to install everything; you can also put several `toutwaf-dp` behind a load balancer, all driven by a single `toutwaf-cp`.

## Installation

### Requirements

| | Linux | Windows |
|---|---|---|
| System | x86_64 or **64-bit ARM (aarch64, Raspberry Pi 3/4/5 and Zero 2 W with a 64-bit OS)**, with systemd. **Validated** (x86_64): AlmaLinux 10, Rocky Linux 9, Debian 12.. The arm64 build is [not yet tested on real hardware](#known-limitations); 32-bit ARM (armv7) is not supported | Windows 10/11 or Windows Server, x64 or **ARM64 (Windows on ARM, never run: build cross-compiled and header-checked only)** (installer [not yet validated on a real Windows host](#known-limitations)) |
| Resources | 1 GB RAM, 2 GB disk | same |
| Rights | `root` (sudo) | **Administrator** PowerShell |
| Network | ports **80** and **443** free (protected sites), port **9443** (console); opened for you in firewalld or ufw, see below | same (Windows Defender Firewall rules created by the installer) |
| Location | a single home, `/var/toutwaf` (`bin`, `conf`, `data`, `logs`), changeable with `--home DIR` | `%ProgramFiles%\ToutWAF`, data in `%ProgramData%\ToutWAF` |

### Linux

```sh
curl -fsSL https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.sh | sudo bash
```

An **interactive menu** is shown (install, update, uninstall, status, show links) with a description of every option. The installer downloads the binaries, **verifies their SHA-256 checksum**, creates a dedicated system user, installs hardened `systemd` services, opens the firewall ports (see below), and finally prints the **summary** (see [First start](#first-start)).

Unattended installation:

```sh
curl -fsSL https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.sh | sudo bash -s -- --install --yes --public-host waf.example.com --console-from 203.0.113.0/24
```

Main options: `--component dp|cp|all`, `--channel stable|dev`, `--version X.Y.Z`, `--public-host`, `--home DIR`, `--no-firewall`, `--console-from CIDR`, `--lang en`, `--tarball FILE` (offline), `--dry-run`. All options: `install.sh --help`.

**Where things go.** A fresh Linux installation uses one home, `/var/toutwaf`, with `bin/`, `conf/`, `data/` and `logs/` below it (`--home DIR` or `TOUTWAF_HOME` to choose another one); the command-line tools (`toutwafctl`, `toutwaf-cp`, `toutwaf-dp`) are linked in `/usr/local/bin`. An installation made before this layout keeps its paths (`/etc/toutwaf`, `/var/lib/toutwaf`, `/var/log/toutwaf`, binaries in `/usr/local/bin`) and is **never moved**.

**Firewall.** When firewalld or ufw is active, the installer opens what the installed components need by default: 80 and 443 for a data plane and the console port (9443) for a control plane. `--console-from CIDR` lets only that address or network reach the console (`0.0.0.0/0` is refused), and `--no-firewall` leaves the firewall alone. The agent port 9444 is **never** opened publicly: allow it only from your own servers. On hosts that use nftables or iptables only, the installer changes nothing and prints the exact commands. Later, **Settings → Firewall** in the console shows the ports and can open the missing ones.

To attach an **additional server** (data plane only) to an existing console:

```sh
curl -fsSL https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.sh | sudo bash -s -- --install --component dp --cp-url https://console.example.com:9444 --enroll-token TOKEN --yes
```

### Windows

In PowerShell, **as administrator**:

```powershell
irm https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.ps1 | iex
```

With options:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.ps1))) -Install -PublicHost waf.example.com
```

### Update, check, uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.sh | sudo bash -s -- --update      # update (backup first, automatic rollback on failure)
curl -fsSL https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.sh | sudo bash -s -- --status      # health check
curl -fsSL https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.sh | sudo bash -s -- --links       # show the access links again
curl -fsSL https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/install.sh | sudo bash -s -- --uninstall   # uninstall (add --purge to erase everything)
```

## First start

At the end of the installation the installer prints a box with everything you need:

1. **The secure console link**, shaped like `https://<IP>:9443/<secret-path>/`, given for **every local address and for the public address**. The secret path is random: any other address on port 9443 returns a neutral 404 page.
2. **The administrator user name and password**, generated and **shown only once**.
3. **A one-time setup link** that opens a wizard to choose your own secret link, user name and password.
4. **The ports** the installer opened, and the exact commands for the ones you must open yourself (nftables, iptables, `--no-firewall`). Don't forget your hosting provider's security group.

The same summary is saved in `/var/toutwaf/conf/INSTALL-SUMMARY.txt` (readable by `root` only). The secret link, user name and password can then be **changed in Settings → Access** and **My account**.

| Port | Use | Open it? |
|---|---|---|
| 80 and 443 / TCP | Traffic of the protected sites (`toutwaf-dp`) | Yes |
| 9443 / TCP | Administration console (`toutwaf-cp`) | Opened by the installer; ideally restricted to your admin network (`--console-from`) |
| 9444 / TCP | Enrolment of remote `toutwaf-dp` servers and host agents | Never opened publicly by the installer: allow it only from your own servers |

**Protect your first site in 5 minutes:**

1. Open the console and follow the wizard (or skip it and add a site later from **Sites**): enter the **domain** and the address of your **origin server**; the help next to that field gives examples.
2. ToutWAF detects your stack (layers, confidence, evidence), proposes a policy template suited to it, and offers a **free certificate** (Let's Encrypt).
3. The site starts in **detection mode**: nothing is blocked, everything is observed.
4. Point your DNS at ToutWAF, let it run for a few days, then read the **report** (what would have been blocked, likely false positives, proposed exceptions).
5. Switch to **blocking mode** in one click, with a one-click rollback.

Useful commands: `toutwafctl doctor` (diagnostics), `toutwaf-cp admin reset-password --user admin` (forgotten password), `toutwaf-cp setup-link --regenerate` (new setup link).

## Channels: stable and beta

| Channel | Branch | For whom | Default install |
|---|---|---|---|
| **stable** | [`main`](https://github.com/qu3ntin01/toutwaf/tree/main) | production | `…/main/install.sh` |
| **beta (dev)** | [`dev`](https://github.com/qu3ntin01/toutwaf/tree/dev) | testing, new features | `…/dev/install.sh` |

The installer remembers the chosen channel (`<home>/conf/installer.conf`); `--channel stable|dev` switches it. The channel can also be chosen on the **Updates** page of the console.

### Updating from the console

The **Updates** page (Administration menu) shows the installed version, the latest version of the selected channel and its release notes. The control plane checks the channel about every 5 minutes and the console announces a new version at once. **Update now** downloads the release, verifies its checksum, installs it and restarts the services **of that server**, with a live progress; if the new version does not start, the previous one is restored automatically. Nothing is offered when the channel is older than the installed version (no silent downgrade). Other data-plane servers are updated through the rolling campaigns of the console or by re-running the installer on them.

## Free edition

Without a licence or a sign-up ToutWAF runs as the **free edition (Free)**, free, professional use included: **up to 3 protected sites, 1 node, 2 users, 1 organisation and 5 million authorised requests per month** (blocked attacks are not counted). An optional free sign-up (confirmed e-mail address, Administration > Licence) moves the installation to **Free+**: **5 sites and 15 million authorised requests per month** (the other limits are the same; the quotas are not added). The ceilings apply to the whole installation, not to each server. The monthly volume is announced, never enforced by a cut: a warning at 80 % then at 100 %, then, if the overrun lasts, a request to move to a paid offer with an announced grace period (30 days by default). Traffic, protection and the console are never interrupted; only the creation of a new site beyond the ceiling is refused, with the limit and the number in use. WAF protection, two-factor authentication and security updates are in every offer.

More sites or nodes (Pro: 15 sites and 2 nodes; Agency: 50 sites and 5 nodes; Enterprise: ceilings by quote) and the advanced features are under licence: advanced load balancing, several organisations (tenants, MSSP), enterprise sign-in (OIDC, SAML, SCIM), SIEM / SOAR / ticketing / threat-intelligence integrations and off-site backups. They stay visible in the console, locked, with a link to the offers; they are never hidden. When a paid licence expires there is a 7-day grace period (everything works, with warnings before and after the expiry), then the rights of the free edition apply, with no cut: your sites stay protected, the last safe policy and the base protection are kept, ToutWAF never switches the WAF off and never cuts traffic; only new configuration and the advanced functions are limited, and sites beyond the free quota are frozen; renewing restores everything at once. Free and Free + are not concerned. Everything else described here is the same product; for larger limits or the advanced features, contact your ToutWAF vendor.


## Known limitations

Let's be transparent about what is not (yet) covered:

- **Platforms**: installation validated end to end on AlmaLinux 10, Rocky Linux 9 and Debian 12 with the binaries of this release; AlmaLinux 9 and Ubuntu 24.04 passed earlier runs on a previous build. Other distributions are untested. **Windows**: the host agent (cluster) is tested on a real Windows Server 2025 (audit, telemetry, Microsoft Defender scan, terminal); the Windows installer script itself is not yet validated end to end on a real host. **ARM64 (Raspberry Pi, Graviton, Ampere)**: the release carries a linux-arm64 package, cross-compiled and checked only under emulation (QEMU): start, health checks, proxied request, blocked SQL injection. It has **not been tested on real ARM hardware** and no performance figure is given. A Raspberry Pi needs a **64-bit** OS (Raspberry Pi OS 64-bit, Ubuntu or Debian arm64); 32-bit ARM (armv7, 32-bit Raspberry Pi OS) is not supported and the installer stops with a message. **Windows on ARM64**: the release carries a windows-arm64 package (cross-compiled; only the PE machine type 0xAA64 was checked), it has never been run on Windows on ARM.
- **Updates from the console** install on the server that runs the console, on Linux with systemd only (elsewhere, for example on Windows, the page shows the command to run); other nodes follow through update campaigns or the installer. **Firewall automation** covers firewalld and ufw (and Windows Defender Firewall rules created by the installer); with nftables or iptables you get the commands to run.
- **Off by default**: HTTP/3 (QUIC, UDP; `--http3` at install time or `listen.h3`, with the UDP port open in the firewall).
- **Not available yet**: PostgreSQL (SQLite only), inspection of gRPC message contents.
- **Lightly tested**: SAML SSO (OIDC tested), the automatic hourly download of the OWASP CRS releases from GitHub over several days (the full CRS 4.31 ruleset itself is tested in our test rig), DNS-01 certificates with Cloudflare/OVH/Route 53, third-party integrations (SIEM, ticketing).
- **Detection**: measured with an independent tool (GoTestWAF: 673/673 attacks blocked, 0/141 false positives) and on a public payload set never seen during development (89.9 % raw; 99.95 % once non-attack fuzz fragments are removed, with the list of excluded fragments disclosed to our reviewers). No WAF catches everything: expect to tune exceptions for your applications. Known trade-offs: MongoDB-style operators (`$ne`, `$where`) in JSON/form fields and two or more `../` in a value are blocked.
- **Performance**: measured on a shared test machine (a few thousand requests per second per instance). Measure on your own hardware before going to production.
- Console and error-message translations were written with the help of automated tools and have not yet been reviewed by native speakers.
- **Little tried on real hardware**: network interfaces (VLAN, bond, IPv6), resilience (tried on several simulated nodes, no real attack, no real Cloudflare account), TLS between nodes for overflow forwarding, restore on a real fresh server. Details in the documentation.
- No certification (ANSSI, PCI DSS, ISO 27001) is claimed.

Targets not built for this release:
- `linux-arm64`: disabled in settings
- `freebsd-amd64`: disabled in settings
- `freebsd-arm64`: disabled in settings

## Versions and downloads

**Version 0.7.0**

| File | OS | Arch | Size | SHA-256 |
|---|---|---|---:|---|
| `toutwaf-linux-amd64.tar.gz` | linux | amd64 | 83.8 MiB | `10b8c2a230adbdd646d399dde1afc85ccc2b6dda33c17dcbdb646f75ef15edb1` |
| `toutwaf-windows-amd64.zip` | windows | amd64 | 87.3 MiB | `5a839f1b9fcd1755ecc8301a559e79ccbf141992e061534d67365cc51274fc8d` |
| `toutwaf-windows-arm64.zip` | windows | arm64 | 84.0 MiB | `611269bc2d5221d02e779a70f4fafb7eaedb9210894bb47d598df28a7b56fab7` |
| `toutwaf-extras.tar.gz` | any | any | 20.6 MiB | `173006b5fc343ef0282a7a13e5c86ca89e2a258bc96a6f36f879fdfc37993312` |

The `toutwaf-extras*.tar.gz` files (OS and architecture `any`) are the extras of the release: the host agent for Windows, which a console hands to other machines. The installer downloads, checks (SHA-256 and signature) and installs them with the archive of the platform; an installation without them works and does not offer Windows.


| Version | Date | Status | Directory |
|---|---|---|---|
| `0.7.0` | 2026-11-21T04:16:01Z | **current** | `releases/0.7.0/` |
| `0.6.3` | 2026-11-20T10:09:17Z | available | `releases/0.6.3/` |
| `0.6.2` | 2026-11-20T05:47:42Z | available | `releases/0.6.2/` |
| `0.6.1` | 2026-11-19T17:17:35Z | available | `releases/0.6.1/` |
| `0.6.0` | 2026-11-16T17:24:34Z | available | `releases/0.6.0/` |
| `0.5.9` | 2026-11-16T12:06:04Z | available | `releases/0.5.9/` |
| `0.5.8` | 2026-11-16T00:24:15Z | available | `releases/0.5.8/` |
| `0.5.7` | 2026-11-15T20:47:03Z | available | `releases/0.5.7/` |
| `0.5.6` | 2026-11-14T02:52:30Z | available | `releases/0.5.6/` |
| `0.5.5` | 2026-11-11T16:11:16Z | available | `releases/0.5.5/` |
| `0.5.4` | 2026-11-10T13:16:18Z | available | `releases/0.5.4/` |
| `0.5.3` | 2026-11-09T22:35:43Z | available | `releases/0.5.3/` |
| `0.5.2` | 2026-11-08T14:22:15Z | available | `releases/0.5.2/` |
| `0.5.1` | 2026-11-08T05:55:10Z | available | `releases/0.5.1/` |
| `0.5.0` | 2026-11-07T23:29:58Z | available | `releases/0.5.0/` |
| `0.4.4` | 2026-11-07T02:11:39Z | available | `releases/0.4.4/` |
| `0.4.3` | 2026-11-03T10:16:08Z | available | `releases/0.4.3/` |
| `0.3.1` | 2026-10-18T07:59:16Z | available | `releases/0.3.1/` |
| `0.2.0-dev.7` | 2026-10-05T14:28:05Z | available | `releases/0.2.0-dev.7/` |
| `0.2.0-dev.6` | 2026-10-04T18:03:29Z | available | `releases/0.2.0-dev.6/` |
| `0.2.0-dev.5` | 2026-10-03T17:20:42Z | available | `releases/0.2.0-dev.5/` |
| `0.2.0-dev.4` | 2026-10-03T13:59:43Z | available | `releases/0.2.0-dev.4/` |
| `0.2.0-dev.1` | 2026-10-02T14:59:13Z | available | `releases/0.2.0-dev.1/` |

Release notes are in [CHANGELOG.md](CHANGELOG.md).

### Verify a download

Every release directory has a `SHA256SUMS` file; `channel.json` repeats the hashes of the current release. The installer checks them automatically. To verify by hand:

```sh
cd releases/0.7.0 && sha256sum -c SHA256SUMS --ignore-missing
```

### Verify a release

From release 0.2.0-dev.7 on, each release directory also holds `SHA256SUMS.sig`: the base64 of the raw 64-byte Ed25519 signature of the exact `SHA256SUMS` file. The installers verify it by default with a public key built into the installer script (key id `3fc61b30f128ff14`) and refuse a release whose signature is invalid, or missing for 0.2.0-dev.7 and later; releases before 0.2.0-dev.7 were published unsigned (checksums only). The public key repeated in `channel.json` is informational and is never used to trust a release: take the key from the installer script or from your vendor. Public key (raw, base64): `gPNG5qkoXV0gO8qTrENwPvxBxHJDbZ6G36UMvAcCJm0=`. To verify by hand (OpenSSL 3 or later):

```sh
V=0.7.0; R=https://raw.githubusercontent.com/qu3ntin01/toutwaf/main/releases/$V
curl -fsSLO "$R/SHA256SUMS" -O "$R/SHA256SUMS.sig"
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; echo 'gPNG5qkoXV0gO8qTrENwPvxBxHJDbZ6G36UMvAcCJm0=' | base64 -d; } | openssl pkey -pubin -inform DER -out release.pem
base64 -d SHA256SUMS.sig > sig.bin
openssl pkeyutl -verify -pubin -inkey release.pem -rawin -in SHA256SUMS -sigfile sig.bin   # "Signature Verified Successfully"
sha256sum -c SHA256SUMS --ignore-missing
```

A release signed with another key, or modified after signing, fails with "Signature Verification Failure". To trust another key (private mirror), set `TOUTWAF_RELEASE_PUBKEY` or create `<home>/conf/release.pub` before installing.

<!-- installer-fingerprints -->
**SHA-256 fingerprints of the installers of release 0.7.0**: compare them with those of the script you downloaded (they are also in the signed `SHA256SUMS`). The one-line command (`curl | bash`) is an act of trust in HTTPS and in the account that publishes this repository; the countermeasure is to download, compare, verify, then run:

| File | SHA-256 |
|---|---|
| install.sh | `f553663b33a3be98596b5e47496b2322ff2c0a34524d59ed20659f5c96a5f1f6` |
| install.ps1 | `cba3dde18811214cd196e674cd24feb3588fb9e949fbfc4bd99cfc202b027071` |

```sh
curl -fsSLO https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/main/install.sh
sha256sum install.sh        # compare with the table above (and with the website)
bash install.sh --verify-self   # checks the file against the signed SHA256SUMS
sudo bash install.sh
```

On Windows: `install.ps1 -VerifySelf`.
<!-- /installer-fingerprints -->

## License and support

ToutWAF is proprietary software: see [LICENSE](LICENSE). For support, commercial licensing or a security report, contact your ToutWAF vendor.
