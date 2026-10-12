# Changelog

All notable changes of ToutWAF binary releases, newest first.

## 0.3.0-dev - 2026-10-12

Development version (`0.3.0-dev`, replaced by each new build).

### Added

- Organisations and managed-service providers: organisations with their own quotas, suspension, safe deletion, moving a site between organisations, invitations, a policy floor that organisations cannot go below, and one report per client. A licensed feature.
- Cluster: supervised servers (one is free) with host security checks, availability probes and thresholds; a standby console with manual promotion; staggered updates; a restore that restarts the service and rolls back if it does not come back; an encrypted backup server for supervised servers.
- ToutWAF Antivirus (Horizon): endpoint enrolment, scans, quarantine and release of a quarantined file, definitions. Licensed; no free tier.
- Mail security gateway: anti-spam, anti-phishing, data-loss prevention, quarantine. Licensed; no free tier.
- IP and geo: degrees by country (watch, harden, challenge, restrict), reputation score with an explanation, trusted addresses, personal lists with import and export, a kernel blocklist helper.
- API security: route profiles with an assistant, schema validation, object-level authorisation checks, WebSocket limits.
- Load balancing: route pools, drain, canary roll-outs.
- Certificates: several ACME authorities with automatic failover; a DNS check that looks at every A and AAAA record and recognises a CDN or proxy before a certificate is requested.
- Automatic rules and definitions: automatic exceptions from your own traffic, a self-test of a new site, a measured precision of each list.
- Doctor: one diagnostic from the machine to the origin of each site, with the cause and the action for every finding.
- Extended audit log (CEF and Syslog exports for a SIEM) and 45 integration modules (6 free).
- AI assistant with a private model (an Ollama or OpenAI-compatible server of your own). The assistant with an external provider sends a request excerpt only on an explicit action.
- Installation: servers can be installed over SSH; Apache behind ToutWAF is supported with the files ToutWAF prepares; the installer refuses a system that cannot work, with the cause; the web stack of a ToutPanel server is applied after the installation by ToutWAF itself (PHP 8.5 by default).
- Console: seven themes, a loading indicator, the brand logo kit, contextual help for tenants.

### Changed

- The free edition is limited to 3 sites, one node, two users and one organisation. Licensed features stay visible and locked ("Licence required"); protection continues after a licence expires and the data plane never consults the licence.
- Requests ToutWAF makes to third parties no longer name the product or its version (neutral User-Agents), including the probes that go to the addresses of a site's DNS names.
- Texts across the ten languages follow one term and one register per concept.
- Version naming: the development version is always named `X.Y.Z-dev` and each publication replaces the previous one; the build identifier tells two builds of the same version apart. The stable channel only ever carries a fully tested version.
- The ToutWAF mark and the product name are fixed on the pages shown to visitors; a client can add their own site name next to them.
- Refusals keep their cause: an error shows its translated title followed by the reason.

### Fixed

- A first visit to a new site is no longer blocked (HTTP/2 `:authority` handling).
- A new site without a certificate is served over HTTP so that HTTP-01 validation can pass, instead of being redirected to the fallback certificate.
- A bare address in a parameter named `ip`, `url` or `host` is no longer treated as a request to an internal address.
- The audit log, dashboard links, analytics measurement and the Wazuh rules file shipped with the integration.

### Security

- Bodies larger than the inspection window are handled by an explicit policy; the window is 1 MiB by default.
- Addresses of administrators can be trusted for a limited time, at their explicit request.
- Nothing identifying leaves an installation: the customer-journey bench plants canary data in the traffic and fails if any of it, or the product name, reaches a simulated third party.

### Honest limits of this build

- No real Windows, macOS or ARM host was used. The installer was exercised on Linux images only.
- No real ToutPanel, router (OPNsense, pfSense) or certificate authority was used; the format of the output of `toutpanel stack apply --json` is still to be confirmed with the ToutPanel team.
- The collective defence network is not offered in this build (it was a local preview that sent nothing).
- Twelve functions carry a note that they have not yet been tried in real conditions (external CAPTCHA, private language model, SAML, kernel blocklist, standby console, virtual address, router files, ACME authorities, antivirus agent, ToutPanel stack, mail gateway, SIEM and ticketing integrations).
- The eight languages other than French and English were not reviewed by native speakers.
- No independent benchmark or penetration test has been done.

## 0.2.0-dev.9 - 2026-10-06

## 0.2.0-dev.9

- **Live attack map** (Map page and a widget on the home dashboard): 3D globe or flat 2D map, live feed or any period, animated attack arcs, top origins and attack types, full-screen and TV mode. Origins are placed at country level.
- **Fuller home dashboard**: threat level, platform health, latest incidents, top ASNs and user agents.
- **Analytics** (new section): visitors online, sessions, pages, sources and campaigns, countries, browsers and devices, behaviour, performance, security traffic, events and goals, comparison with the previous period, CSV export. Cookieless; a first-party tracker injected by ToutWAF measures screen size, scroll depth, engaged time, Core Web Vitals and custom events, switchable per site, with an allowed-origins list and a manual snippet mode.
- **Customisable pages**: block, rate-limit, browser check, captcha, access denied, maintenance and error pages with a gallery of designs, a no-code editor, an advanced HTML editor, live preview, versions and per-site overrides. Configurable captcha: proof of work, built-in image captcha, Turnstile, hCaptcha, reCAPTCHA.
- **Network check** in the Add server and Web servers wizards: required ports in both directions, live verification, ready-to-copy firewall rules, one-click fixes where possible.
- **ToutPanel**: "Also create this site in ToutPanel" in Add site (panel API token), "This machine" proposed first in the Web servers wizard, ToutWAF is the only WAF offered.
- **Agent and data plane verify the control plane by its certificate fingerprint** instead of the host name, so enrolment works by IP address or NAT address; new `toutwaf-cp tls regenerate` keeps the key.
- Sidebar shows only the section of the current page; the version badge shows the running version; the top bar shows the distribution with a logo; translations reviewed (not by native speakers).
- **ToutPanel 0.5.1 integration**: installing ToutPanel from ToutWAF with every installer option (loaded from the published options file), strict link mode, automatic certificate pinning from the panel heartbeat, official uninstall, honours rate-limit delays, clear message when the panel refuses the WAF address, "Behind ToutWAF" check, deep link to a site's SSL tab, notice when the panel drops the access token.
- **Web server section** (when linked to ToutPanel): sites, FTP, PHP, backups, DNS zones through the panel API; certificates held by ToutWAF and drivable from ToutPanel; ToutPanel integration on/off switch in Cluster.
- Fixes: site creation in ToutPanel (required domains field), a second server created when the agent was reinstalled, long single-line SSH output truncated, AI assistant drawer unreadable on glass themes.

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
