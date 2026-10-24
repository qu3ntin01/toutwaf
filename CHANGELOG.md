# Changelog

Format: [Keep a Changelog](https://keepachangelog.com). Versions follow SemVer. The repository format version (see `docs/ARCHITECTURE.md`) and the
API version (`/api/v1`) change independently of the program version and are never changed incompatibly within a major version.

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
