# Changelog

All notable changes of ToutWAF binary releases, newest first.

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
