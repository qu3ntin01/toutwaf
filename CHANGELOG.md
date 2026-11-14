# Changelog

Format: [Keep a Changelog](https://keepachangelog.com). Versions follow SemVer. The repository format version (see `docs/ARCHITECTURE.md`) and the
API version (`/api/v1`) change independently of the program version and are never changed incompatibly within a major version.

## [0.2.1] - 2026-11-13

### Fixed
- **Installer, first installation**: the datastore folder given with `--datastore NAME=/path` is now created by the installer (as root, then given to the service user) before `server init`. Before, `/srv/...` could not be created by the service user and the installation stopped on "creating the server configuration" with the real cause hidden.
- **Installer**: the state folder is given back to the service user before the service starts (a command run as root in it could leave `config.json` and `tokens.json` unreadable by the service: every request answered "setup pending").
- **Installer**: the system update is run with `--skip-broken` (dnf, yum): a conflicting package no longer stops an installation.
- **Web interface**: the Updates page no longer fails with "Invalid time value" (the release date is an ISO date, read as such); the date formatters show a dash for an invalid date instead of breaking the page.

### Changed
- **Aurora is the default style** of the web interface (Classic stays one choice away in the Style menu).

## [0.2.0] - 2026-11-10

### Added
- **First-run setup link** (`docs/i18n/*/SETUP.md`). The last screen of `install.sh` / `install.ps1` is one block: what was installed and where, a **single-use, 60-minute setup link** (`https://HOST:8007/setup/KEY`, 256-bit key, stored only as a SHA-256, tied to the fingerprint of the server certificate, never logged), the fingerprint to compare, the firewall reminder, how to get a new link, how to uninstall, and a text QR code when `qrencode` is installed. The link opens a wizard in ten languages: administrator (strength meter, 12 characters minimum, common-password list, optional TOTP with QR code and eight recovery codes), first admin token shown once (and a token for ToutWAF), server settings (external address with a reachability and certificate-name check from the server, listen address, first datastore on disk or S3 with write and free-space checks, default retention, e-mail and webhook notifications, update channel and automatic updates), summary and "Finish", which consumes the link. Until then the web interface and the API refuse everything except the wizard (`/health` and API calls with a token that root made on the machine still work, which keeps ToutWAF's remote deployment running); a wrong key is rate limited (5 per address, 40 in total).
- `toutwaf-backup server setup-link [--new] [--reopen]` (status or a new link; a new link invalidates the previous one), `server user hash`, `server init --no-setup-link | --admin-user | --admin-password-hash-file | --admin-token-file | --machine`.
- Installer: `--no-setup-link`, `--admin-user`, `--admin-password-hash-file`, `--admin-token-file`, `--no-qr` (the unattended path keeps working: without the wizard the first admin token is printed as before). Recovery codes for two-factor sign-in (each works once).
- `tools/test-installer-setup.sh` (installer against the real binary: block, hash-only storage, ten languages, unattended paths, a running server gated until the wizard is done), `tools/e2e-ui/setup.js` (the wizard in a browser).

### Changed
- **Web interface design aligned with ToutPanel**: the new default style is **Classic** (the ToutPanel default: flat 248 px menu with a hairline edge, 56 px top bar, white cards with 12 px radii, 8 px controls, Inter and JetBrains Mono, the blue accent #2563eb, the same light and dark tokens). **Aurora** (the glass style used until now) stays one click away in the new Style menu of the top bar and the sign-in page (remembered per browser). Fonts are self-hosted (SIL OFL, copied from ToutPanel). The contrast test now covers both styles in both modes; the first-run wizard and the Updates page follow the style like every page. The sign-in field accepts a recovery code (14 characters).
- `server init` makes the setup link instead of an admin token (use `--no-setup-link` for the old behaviour). A server without `setup.json` (every server installed before) is not gated.

## [0.1.2] - 2026-10-24

### Fixed
- Dashboard: the 30-day backup calendar drew huge cells stretched to the width of the card; the cells are now fixed squares (20 px, 18 px on a phone), left aligned.
- A stray "null" appeared in the "Resume from S3" dialog (a conditional child passed to the native `append`). The interface now leaves out `null`, `undefined` and `false` children everywhere, and a browser sweep (`tools/e2e-ui/sweep.js`) opens every dialog and page in each of the ten languages and fails on "null", "undefined", "NaN" or "[object Object]".

## [0.1.1] - 2026-10-24

### Added
- **New web interface** with the ToutWAF design system (aurora theme, glass cards, grouped sidebar, light/dark/system, reduced motion, no CDN, ToutWAF icons and logo): dashboard with gauges, history charts, dedup and compression
  ratios, 30-day heat map and alerts; datastores with growth, days until full, namespaces, quotas, protection and offsite copies; machine inventory; snapshot browser with search, download, restore wizard and compare; jobs with a
  human-readable schedule editor and next-runs preview; live tasks with progress, log and cancel; access (tokens, users with Argon2id passwords and TOTP two-factor, sessions); audit viewer with filters and CSV/JSON export;
  notifications; settings; reports; system page with health checks and diagnostics bundle; help. Responsive down to 360 px, keyboard accessible, contrast-tested in both themes.
- **S3 backups, first class** (`docs/S3.md`): S3 datastore from a wizard (provider, endpoint, region, bucket, prefix, path-style, private CA, Object Lock, storage class, keys), **connection test** (`s3 test`, API, button: settings,
  keys, endpoint, bucket, listing, write, read, delete, Object Lock), **offsite copy to S3** as a sync job (bandwidth cap, read-back verification), **resume from S3** (`datastore import-s3`, `POST /datastores/import-s3`, wizard).
  Keys typed in the interface are stored 0600 in `<state>/secrets/s3/` and never returned, logged or mirrored; `--s3-credentials-stdin`; `datastore create`, `s3 test`, `server offsite s3` commands.
- ToutWAF link: `POST /link/provision` chooses a local or S3 datastore per machine and can schedule an offsite copy to S3; capabilities `s3`, `s3-offsite`, `s3-import`, `storage-test`; answers carry `backend`, `s3`, `offsite_job`.
- `client diff` (compare two snapshots on the client, the only place that can read an encrypted catalog); server-side compare for unencrypted snapshots.
- Statistics, usage history with growth estimate, client inventory, task progress/cancel/live log, snapshot notes, schedule preview with time zones, default language/time zone/retention settings, monthly report, diagnostics bundle.
- Browser tests (Playwright) over the real binaries, `tools/fake-s3` (the S3 fake over TCP), `tools/demo-seed` (a populated demo server produced by real runs).

- **Ten languages everywhere** (en fr es de it pt nl ru zh ar): the web interface (runtime catalogs, plurals, Intl formatting, right-to-left layout for Arabic, language chosen from the browser or the server setting, remembered), the command line (help, messages, errors, progress; `--lang`, `TWB_LANG`, `LC_ALL`, `LANG`; JSON output, exit codes and error codes unchanged), the installers `install.sh` and `install.ps1` (embedded catalogs, `--lang`, same mechanism as ToutWAF), notifications and alerts (server language setting, request language), and documentation pages in `docs/i18n/<lang>/` with the README pages of the public branch. Generated by `deploy/tools/gen-installer-i18n.py` and `tools/gen-docs-i18n.py`; checked by tests. The translations are machine-written and not reviewed by native speakers.
- Version 0.1.1: documentation of the API endpoints added since 0.1.0 (users, sessions, TOTP, statistics, history, clients, compare, search, notes, system, reports).

### Fixed
- A running server now picks up users and sessions changed by the command line (`server user add/delete/...`).
- Per-address rate limiter no longer drains when the clock steps backwards.
- The mirror of `datastore.json` in a bucket no longer carries local credential or CA file paths; recovery uses the settings given at recovery time.
- The "less than 5 % free space" alert for an S3 datastore says it concerns the server's disk (metadata), not the bucket.

## [0.1.0-dev] - 2026-10-23

First development release. Everything listed here was tested end to end on Linux (see `docs/PERFORMANCE.md` and the final test report in the commit
history); Windows-specific parts are compiled and vetted but **not tested on a real Windows system** and are marked as such in the documentation.

### Added (second milestone)
- Per-token and per-namespace quotas: hard and soft byte limits (distinct stored chunks, shared chunks counted once), snapshot and chunk counts, per-token bandwidth caps; enforced on upload (`507`) and commit; soft-limit notification and
  alert; API (`PATCH /tokens/{id}`, `GET /datastores/{ds}/quotas`, `ns_quotas`), CLI (`token create/set`, `datastore ns-quota`, `client status`), web UI.
- S3-compatible object-storage chunk store (AWS S3, MinIO, Wasabi, Backblaze B2, Scaleway, OVH, Cloudflare R2): SigV4, path-style and virtual-hosted addressing, retries with backoff, multipart upload, optional Object Lock,
  lifecycle-safe garbage collection, scrub through the object API, metadata mirror and `--recover`. Tested against an in-process fake only (see `docs/TESTING.md`).
- `client mount`: read-only FUSE view of a snapshot on Linux (lazy, cached, authenticated chunk reads); `-tags nofuse` leaves it out.
- Install policy: the server refuses to run on the machine that runs ToutWAF (installers and `server run`; lab override `TWB_ALLOW_SAME_HOST=1`); `machine_id_hash` in the pairing contract.
- Distribution as the `toutwaf-backup` branch of the public ToutWAF repository, signed with the main product's key; `tools/build-release.sh --out DIR` writes the branch tree.

### Added
- Server: datastores on local paths; content-defined chunking (FastCDC style, keyed gear table); SHA-256 / HMAC-SHA-256 content addressing; zstd
  compression; deduplication across snapshots, groups and clients; snapshot catalogue with namespaces and groups (type/id); verification and scrub jobs;
  prune with keep-last/hourly/daily/weekly/monthly/yearly/within; garbage collection with a grace period; append-only mode per datastore and per token;
  immutability period; datastore quotas; API tokens with four roles (admin, writer, reader, audit) scoped to datastores and namespaces; TLS with a generated
  certificate and fingerprint pinning; HTTP/2; per-address rate limiting and authentication lockout; hash-chained audit log; Prometheus metrics; health
  endpoints; scheduled jobs (cron syntax); sync / replication (pull, push, offsite copy to a local path) without needing keys; notifications by e-mail
  (SMTP, STARTTLS) and signed webhooks; stale-backup, quota, disk and failed-job alerts; embedded web interface (French and English, light and dark,
  keyboard and screen-reader friendly).
- Client: files and directories with include/exclude patterns, one-file-system, `CACHEDIR.TAG` and marker files; fast incremental backups with a
  change-detection cache that is checkpointed (interrupted backups resume); permissions, ownership, extended attributes (including POSIX ACLs),
  symlinks, hard links, sparse files, FIFOs and device nodes; database dumps from stdin or `--command`; pre/post scripts; restore (full, partial, to another
  directory, verified); `ls`, `find`, `cat` without restoring; local web browser for encrypted snapshots; client-side encryption (XChaCha20-Poly1305,
  Argon2id, key file, paper key, escrow copy, passphrase rotation); bandwidth limits; retries with back-off; systemd timer and Windows Task Scheduler
  generation; client-side prune.
- ToutWAF link: pairing (`toutwaf-backup link`), provisioning of datastores and scoped tokens, status, signed event webhooks, the engine contract
  (`toutwaf-backup engine`, JSON events, fixed exit codes). Contract `toutwaf-backup-link/1`, engine `toutwaf-backup-engine/1`.
- Installers for Linux (`install.sh`, tested) and Windows (`install.ps1`, written but not tested), signed release builder `tools/build-release.sh`
  (Ed25519, the scheme of the main ToutWAF product).
- Documentation: architecture and format specification, security model, installation, restore runbook, link contract, performance report.

### Known limits
- No FUSE mount (use `client browse`, `ls`, `find`, `cat` and `restore --path`).
- Windows: VSS, NTFS ACLs, long paths, the service wrapper and `install.ps1` are untested on real Windows.
- No S3 / object-storage back end: datastores are local directories (an offsite copy goes to a second server or a mounted disk).
- A snapshot is identified by its start second: two backups of the same group in the same second conflict.
