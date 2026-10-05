# Changelog

All notable changes of ToutWAF binary releases, newest first.

## 0.2.0-dev.8 - 2026-10-05

## 0.2.0-dev.8

- **ToutPanel installed from ToutWAF always uses ToutWAF**: the other WAF engines (BunkerWeb, SafeLine) are no longer offered in the Add server wizard.
- **Web servers wizard**: "This machine" (same server as ToutWAF) is proposed first, "Another server" is the alternative.
- **Fix: agent installation over SSH failed with "Could not resolve host"** when the console was opened through a name only the administrator's computer could resolve. New field "ToutWAF address as seen from the server", a pre-flight check before anything is installed (name resolution and TLS connection, with clear instructions), a safer default address, and new console certificates that also list the machine's IP addresses (existing certificates are not regenerated).
- **Fix: the version badge in the menu** showed a fixed 1.0.2; it now shows the version that is really running.
- **Top bar**: shows the running distribution, its version and a logo (for example AlmaLinux 10, amd64) instead of just the system and architecture. Logos are simplified marks.
- Same binaries otherwise as 0.2.0-dev.7 (signed release, Linux and Windows on Intel/AMD and ARM64).

## 0.2.0-dev.7 - 2026-10-05

## 0.2.0-dev.7

- **Signed releases**: `SHA256SUMS` is now signed (Ed25519) and the installers verify the signature with a built-in public key before installing or updating. A bad signature always aborts; a missing signature aborts for 0.2.0-dev.7 and later. Releases before dev.7 are unsigned. On systems whose OpenSSL cannot verify Ed25519 (RHEL-family 8) the installer uses a built-in Python verifier.
- Same binaries and features as 0.2.0-dev.6 (Linux and Windows, Intel/AMD and ARM64; Docker image; ToutPanel web servers; installer compatibility check).

## 0.2.0-dev.6 - 2026-10-04

## 0.2.0-dev.6

- **Linux compatibility**: the installer checks the system before changing anything (`--check-compat`, `--skip-os-check`) and lists compatible versions. Full install test passed on 30 container images: AlmaLinux/Rocky/Oracle 8-10, CentOS Stream 9-10, Fedora 41-44, Amazon Linux 2023, Debian 11-13, Ubuntu 20.04-26.04, openSUSE Leap 15.6/16.0, Tumbleweed, Arch; RHEL 8-10 validated on Red Hat UBI images. New families: SUSE, Arch, Amazon.
- **ARM64** (Raspberry Pi 64-bit, Graviton, Ampere) and **Windows ARM64**: binaries included. Emulation-tested only (Linux), never run on real ARM hardware; 32-bit ARM is refused.
- **Docker image** (amd64/arm64) with compose files for Mac (Apple Silicon and Intel) and any Docker host; native macOS is not provided.
- **ToutPanel integration**: Cluster > Web servers (install through command or SSH, dedicated token, TLS pin endpoint, heartbeat and status).
- Free edition documented: 5 sites, 1 node, 2 users, 1 organisation, 50 million requests per month.

## 0.2.0-dev.5 - 2026-10-03

Pre-release of ToutWAF 0.2.0 (dev channel).

- Product updates from the console: pick the channel (stable or dev), a banner and notification as soon as a new version is published (checked every 5 minutes), release notes, "Update now" with live progress and automatic rollback.
- Host firewall: the installer opens the ports ToutWAF needs automatically (firewalld / ufw), with a Settings > Firewall card to open them later; the agent port 9444 is never opened publicly.
- New default installation directory: /var/toutwaf (bin, conf, data, logs; option --home). Existing installations keep their paths.
- Free edition: 5 sites, 1 node, 2 users.
- Much better detection of the technology behind your site in the first-run wizard (WordPress, Joomla, Drupal, Magento, PrestaShop, Laravel, Django, Next.js, Nextcloud and many more) with confidence and evidence; the wizard can be skipped; help next to the origin URL field.
- The certificate order button now shows its errors; stale console tokens are renewed automatically.
- Menu sections start folded; Definitions table fits smaller screens.
- Known limits: HTTP/3, PostgreSQL and ARM64 packages are not included yet; the Windows installer script is not yet validated end to end on a real Windows host (the Windows agent is).

## 0.2.0-dev.4 - 2026-10-03

Pre-release of ToutWAF 0.2.0 (dev channel).

- New default look: Aurora (light, blue accent) with the Plus Jakarta Sans font; six other themes, light/dark/system mode and your own accent colour.
- Cluster: add existing Linux and Windows servers from the console, with live resources, a security score, an audit with one-click remote fixes (preview and undo), mini-EDR alerts, ClamAV / Microsoft Defender scans, a remote terminal and an install over SSH (including the ToutPanel web server).
- Automatic definitions: 19 sources updated every hour (OWASP CRS, Emerging Threats Open signatures converted to virtual patches, IP reputation lists, Tor exits, GeoIP, bad user agents, CISA KEV advisories), with integrity checks, automatic rollback and a master switch in the console.
- Much stronger detection engine: decoding of hidden payloads (base64, hex, UTF-7, double encoding), new NoSQL, LDAP, mail-header, SSI, SSTI, command and path-traversal detectors. Measured with GoTestWAF: 673/673 attacks blocked, 0/141 false positives; 89.9 % raw on a public payload set never seen during development (99.95 % without non-attack fuzz fragments).
- Setup assistant: checks ports 80/443 from outside, certificates and the data plane.
- The installer speaks 10 languages: it follows your system language, or use --fr, --de, --es, --it, --pt, --nl, --ru, --zh, --ar, --en.
- Known limits: HTTP/3, PostgreSQL and ARM64 packages are not included yet; the Windows installer script is not yet validated end to end on a real Windows host (the Windows agent is).

## 0.2.0-dev.3 - 2026-10-03

First public release of ToutWAF, a self-hosted web application and API protection platform.

- Web application firewall with detection for SQL injection, XSS, command injection, file inclusion, SSRF, XXE, template injection and more, with a detection mode before blocking.
- API protection: OpenAPI and GraphQL validation, JWT checks, rate limiting per consumer, response data-leak prevention.
- Bot management, anti-DDoS rate limiting, IP and country rules, IP reputation lists and automatic bans.
- Web console in 10 languages with 7 themes, accent colours, live events, false-positive handling and policy versions with rollback.
- Secure console access: secret panel link, one-time setup link, changeable account and password.
- Backups with off-site copies (S3-compatible storage, SFTP, WebDAV), encryption, retention and restore tests.
- Reverse proxy with TLS, HTTP/2, load balancing and health checks; ACME certificates.
- Installer for Linux (AlmaLinux, Rocky, Debian, Ubuntu) and Windows with install, update and uninstall.
- Known limits: HTTP/3, PostgreSQL and ARM64 packages are not included yet; the Windows installer has not been validated on a real Windows host.

## 0.2.0-dev.2 - 2026-10-02

First public release of ToutWAF, a self-hosted web application and API protection platform.

- Web application firewall with detection for SQL injection, XSS, command injection, file inclusion, SSRF, XXE, template injection and more, with a detection mode before blocking.
- API protection: OpenAPI and GraphQL validation, JWT checks, rate limiting per consumer, response data-leak prevention.
- Bot management, anti-DDoS rate limiting, IP and country rules, IP reputation lists and automatic bans.
- Web console in 10 languages with 7 themes, accent colours, live events, false-positive handling and policy versions with rollback.
- Secure console access: secret panel link, one-time setup link, changeable account and password.
- Backups with off-site copies (S3-compatible storage, SFTP, WebDAV), encryption, retention and restore tests.
- Reverse proxy with TLS, HTTP/2, load balancing and health checks; ACME certificates.
- Installer for Linux (AlmaLinux, Rocky, Debian, Ubuntu) and Windows with install, update and uninstall.
- Known limits: HTTP/3, PostgreSQL and ARM64 packages are not included yet; the Windows installer has not been validated on a real Windows host.

## 0.2.0-dev.1 - 2026-10-02

First public release of ToutWAF, a self-hosted web application and API protection platform.

- Web application firewall with detection for SQL injection, XSS, command injection, file inclusion, SSRF, XXE, template injection and more, with a detection mode before blocking.
- API protection: OpenAPI and GraphQL validation, JWT checks, rate limiting per consumer, response data-leak prevention.
- Bot management, anti-DDoS rate limiting, IP and country rules, IP reputation lists and automatic bans.
- Web console in 10 languages with 7 themes, accent colours, live events, false-positive handling and policy versions with rollback.
- Secure console access: secret panel link, one-time setup link, changeable account and password.
- Backups with off-site copies (S3-compatible storage, SFTP, WebDAV), encryption, retention and restore tests.
- Reverse proxy with TLS, HTTP/2, load balancing and health checks; ACME certificates.
- Installer for Linux (AlmaLinux, Rocky, Debian, Ubuntu) and Windows with install, update and uninstall.
- Known limits: HTTP/3, PostgreSQL and ARM64 packages are not included yet; the Windows installer has not been validated on a real Windows host.
