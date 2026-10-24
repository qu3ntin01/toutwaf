#!/usr/bin/env bash
# ToutWAF Backup installer for Linux (server or client role). Idempotent: run it again to upgrade, repair or reconfigure.
#
#   curl -fsSL <base-url>/install.sh | sudo bash -s -- --role server
#   sudo ./install.sh --role client
#
# What it does: downloads channel.json, the signed SHA256SUMS and the archive for this CPU; VERIFIES the Ed25519 signature of
# SHA256SUMS with the public key baked into this script (needs OpenSSL 3), then the SHA-256 of the archive; installs the binary
# atomically (the previous one is kept as toutwaf-backup.prev); for the server role creates a system user, a state directory, the
# systemd unit and, on first install, the configuration and the first admin token. Nothing is started unless asked.
set -euo pipefail

# shellcheck disable=SC2034  # read by the release tooling (min_installer in channel.json)
INSTALLER_VERSION=1
DEFAULT_CHANNEL="dev"
DEFAULT_BASE_URL="https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/toutwaf-backup"
FALLBACK_BASE_URL="https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup"     # used only when the primary cannot be reached and no base URL was chosen
RELEASE_PUBKEY="V7tJBQsSrIsDTGIqlFhJZ8q4t/Fc8iNvg/cKkfRDATA="

BASE_EXPLICIT=0; BASE_URL="$DEFAULT_BASE_URL"
[ -z "${TOUTWAF_BACKUP_BASE_URL:-}" ] || { BASE_URL="$TOUTWAF_BACKUP_BASE_URL"; BASE_EXPLICIT=1; }
ROLE="" CHANNEL="$DEFAULT_CHANNEL" VERSION="" PREFIX="/usr/local" DESTDIR="" SERVICE_USER="toutwaf-backup"
STATE_DIR="/var/lib/toutwaf-backup" CONF_DIR="/etc/toutwaf-backup" LISTEN=":8007" EXTERNAL_URL="" NO_SYSTEMD=0 START=0 UNINSTALL=0 PURGE=0 YES=0 FORCE=0 INIT=1 DATASTORE=""
PUBKEY_OVERRIDE="" PUBKEY_FILE=""

usage() {
  cat <<USAGE
Usage: install.sh --role server|client [options]

  --role ROLE            server (the backup server) or client (the machine to protect). Required.
  --channel NAME         stable (default) or dev
  --version X.Y.Z        install this version instead of the channel's latest
  --base-url URL         where channel.json and releases/ are served (default: $DEFAULT_BASE_URL, then $FALLBACK_BASE_URL if it is unreachable; or set TOUTWAF_BACKUP_BASE_URL)
  --prefix DIR           install the binary in DIR/bin (default /usr/local)
  --state-dir DIR        server state directory (default /var/lib/toutwaf-backup)
  --listen ADDR          server listen address for the first configuration (default :8007)
  --external-url URL     https URL clients use to reach the server (written into the first configuration)
  --datastore NAME=PATH  create this datastore at first configuration (e.g. main=/srv/backups/main)
  --no-init              server: do not create the configuration (do it yourself with 'toutwaf-backup server init')
  --start                server: enable and start the service now
  --no-systemd           do not touch systemd (containers, other init systems)
  --user NAME            service user (default toutwaf-backup)
  --destdir DIR          stage everything below DIR (packaging, tests); implies --no-systemd and no user creation
  --uninstall            remove the binary and the units (data is kept)
  --purge                with --uninstall: also remove the configuration, the state directory (including its datastores) and the user
  --yes                  do not ask for confirmation
  --pubkey-file FILE     use the release public key in FILE (the release.pub published next to this script) instead of the baked-in one
  --force                reinstall even if this version is already installed
  -h, --help             this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; BASE_EXPLICIT=1; shift 2 ;;
    --pubkey-file) PUBKEY_FILE="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    --listen) LISTEN="${2:-}"; shift 2 ;;
    --external-url) EXTERNAL_URL="${2:-}"; shift 2 ;;
    --datastore) DATASTORE="${2:-}"; shift 2 ;;
    --no-init) INIT=0; shift ;;
    --start) START=1; shift ;;
    --no-systemd) NO_SYSTEMD=1; shift ;;
    --user) SERVICE_USER="${2:-}"; shift 2 ;;
    --destdir) DESTDIR="${2:-}"; NO_SYSTEMD=1; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --pubkey) PUBKEY_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; usage >&2; exit 64 ;;
  esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'install.sh: error: %s\n' "$*" >&2; exit 1; }

case "$ROLE" in server|client) ;; *) usage >&2; die "--role server or --role client is required" ;; esac
case "$CHANNEL" in stable|dev) ;; *) die "--channel must be stable or dev" ;; esac
[[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid --user"
[ -z "$PUBKEY_FILE" ] || { [ -r "$PUBKEY_FILE" ] || die "cannot read $PUBKEY_FILE"; PUBKEY_OVERRIDE="$(tr -d " \n\r" <"$PUBKEY_FILE")"; }
[ -z "$PUBKEY_OVERRIDE" ] || { warn "using the public key given with --pubkey instead of the one baked into this script"; RELEASE_PUBKEY="$PUBKEY_OVERRIDE"; }
[[ "$RELEASE_PUBKEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "this installer has no valid release public key (it is baked in by tools/build-release.sh; use the install.sh served with the release)"

if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then die "run as root (sudo), or use --destdir to stage"; fi
D="$DESTDIR"

# ---- a backup SERVER must not live on a machine that runs ToutWAF ------------------------------------------------------------------
# A backup stored on the machine it protects does not survive the loss of that machine. Markers are looked up below $D (the staging root).
host_guard() {
  [ "$ROLE" = server ] || return 0
  [ "$UNINSTALL" -eq 0 ] || return 0
  [ "${TWB_ALLOW_SAME_HOST:-}" = 1 ] && return 0
  local found="" p b
  for b in toutwaf-cp toutwaf-dp toutwafctl; do
    for p in /usr/local/bin /usr/bin /bin /var/toutwaf/bin /opt/toutwaf/bin; do [ -e "$D$p/$b" ] && found="$found $p/$b"; done
    [ -n "$D" ] || { command -v "$b" >/dev/null 2>&1 && found="$found $(command -v "$b")"; }
  done
  for p in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    for b in toutwaf-cp.service toutwaf-dp.service; do [ -e "$D$p/$b" ] && found="$found $p/$b"; done
  done
  for p in /var/toutwaf /var/lib/toutwaf /etc/toutwaf /opt/toutwaf; do [ -d "$D$p" ] && [ -n "$(ls -A "$D$p" 2>/dev/null)" ] && found="$found $p"; done
  if [ -z "$D" ]; then
    local l
    l="$( (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | awk '{print $4}' | grep -E '[:.](9443|9444)$' | head -2 | tr '\n' ' ' || true)"
    [ -z "$l" ] || found="$found listening-port:$l"
  fi
  [ -n "$found" ] || return 0
  cat >&2 <<MSG
install.sh: REFUSED / REFUS
  EN: ToutWAF is installed on this machine (found:$found).
      The ToutWAF Backup SERVER must run on a DIFFERENT machine: a backup stored on the machine it protects does not survive the loss of
      that machine (disk failure, ransomware, fire, theft). Install the server on another host. The backup CLIENT (--role client) can be installed here.
  FR: ToutWAF est installé sur cette machine (trouvé :$found).
      Le SERVEUR ToutWAF Backup doit tourner sur une AUTRE machine : une sauvegarde stockée sur la machine qu'elle protège ne survit pas
      à la perte de cette machine (panne de disque, rançongiciel, incendie, vol). Installez le serveur sur un autre hôte.
      Le CLIENT de sauvegarde (--role client) peut être installé ici.
MSG
  exit 3
}
host_guard
BIN_DIR="$D$PREFIX/bin"
BIN="$BIN_DIR/toutwaf-backup"
UNIT_DIR="$D/etc/systemd/system"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

use_systemd() { [ "$NO_SYSTEMD" -eq 0 ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }
confirm() { [ "$YES" -eq 1 ] && return 0; [ -t 0 ] || die "$1 -- add --yes to confirm in a non-interactive run"; printf '%s [y/N] ' "$1"; read -r a; [[ "$a" =~ ^[Yy] ]]; }

# ---- uninstall ----------------------------------------------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  if use_systemd; then
    systemctl disable --now toutwaf-backup-server.service 2>/dev/null || true
  fi
  rm -f "$BIN" "$BIN.prev" "$UNIT_DIR/toutwaf-backup-server.service"
  use_systemd && systemctl daemon-reload || true
  say "Removed $BIN and the server unit."
  say "Client timers you created with 'client schedule' (toutwaf-backup-*.timer) are left alone: disable them yourself."
  if [ "$PURGE" -eq 1 ]; then
    confirm "PURGE deletes $D$CONF_DIR and $D$STATE_DIR (including any datastore inside it). Datastores elsewhere are kept. Continue?" || die "aborted"
    case "$CONF_DIR$STATE_DIR" in ""|/|*" "*) die "refusing to purge: bad --state-dir" ;; esac
    [ "$STATE_DIR" != "/" ] && [ "$CONF_DIR" != "/" ] || die "refusing to purge /"
    rm -rf "${D}${CONF_DIR}" "${D}${STATE_DIR}"
    if [ -z "$D" ] && id "$SERVICE_USER" >/dev/null 2>&1; then userdel "$SERVICE_USER" 2>/dev/null || true; fi
    say "Configuration, state and user removed."
  else
    say "Configuration ($CONF_DIR) and state ($STATE_DIR) are kept. Add --purge to delete them."
  fi
  exit 0
fi

# ---- download -----------------------------------------------------------------------------------------------------------------
fetch() { # url dest
  if command -v curl >/dev/null 2>&1; then curl -fsSL --proto '=https,file' --tlsv1.2 --retry 3 -o "$2" "$1" 2>/dev/null || curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
  else die "curl or wget is required"; fi
}
case "$BASE_URL" in https://*|http://127.0.0.1*|http://localhost*|file://*) ;; *) die "--base-url must be https:// (http only for localhost)" ;; esac
command -v openssl >/dev/null 2>&1 || die "openssl 3 is required to verify the release signature"
OSSL_MAJOR="$(openssl version | sed -E 's/^[A-Za-z]+ ([0-9]+)\..*/\1/')"
[ "${OSSL_MAJOR:-0}" -ge 3 ] 2>/dev/null || die "openssl 3 or newer is required to verify Ed25519 signatures (found: $(openssl version)). Upgrade it, or install from a machine that has it and copy the binary."

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported CPU $(uname -m) (supported: x86_64, aarch64)" ;;
esac
[ "$(uname -s)" = Linux ] || die "this installer is for Linux; use install.ps1 on Windows"

if ! fetch "$BASE_URL/channel.json" "$TMP/channel.json"; then
  if [ "$BASE_EXPLICIT" -eq 0 ] && [ -n "$FALLBACK_BASE_URL" ]; then
    warn "cannot reach $BASE_URL, trying $FALLBACK_BASE_URL (the signature is verified the same way)"
    BASE_URL="$FALLBACK_BASE_URL"
    fetch "$BASE_URL/channel.json" "$TMP/channel.json" || die "cannot download channel.json from either location"
  else
    die "cannot download $BASE_URL/channel.json"
  fi
fi
LATEST="$(sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]*)".*/\1/p' "$TMP/channel.json" | head -1)"
YANKED="$(sed -nE 's/^[[:space:]]*"yanked":[[:space:]]*\[(.*)\].*/\1/p' "$TMP/channel.json" | head -1)"
[ -n "$LATEST" ] || die "the channel has no version yet (channel.json says nothing is published)"
WANT="${VERSION:-$LATEST}"
[[ "$WANT" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "bad version '$WANT'"
if printf '%s' "$YANKED" | grep -q "\"$WANT\""; then [ "$FORCE" -eq 1 ] || die "version $WANT was withdrawn (yanked); use --force only if you know why"; fi

CUR=""
if [ -x "$BIN" ]; then CUR="$("$BIN" version 2>/dev/null | sed -nE 's/^toutwaf-backup ([^ ]+).*/\1/p' || true)"; fi
if [ "$CUR" = "$WANT" ] && [ "$FORCE" -eq 0 ]; then
  say "toutwaf-backup $CUR is already installed and up to date."
else
  ASSET="toutwaf-backup-linux-$ARCH.tar.gz"
  REL="$BASE_URL/releases/$WANT"
  say "Downloading toutwaf-backup $WANT ($CHANNEL, linux/$ARCH)..."
  fetch "$REL/SHA256SUMS" "$TMP/SHA256SUMS" || die "cannot download $REL/SHA256SUMS"
  fetch "$REL/SHA256SUMS.sig" "$TMP/SHA256SUMS.sig" || die "cannot download the signature $REL/SHA256SUMS.sig"
  # signature: base64 of the raw 64-byte Ed25519 signature over SHA256SUMS; the public key is the raw 32 bytes in base64
  { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$RELEASE_PUBKEY" | base64 -d; } >"$TMP/pub.der"
  [ "$(wc -c <"$TMP/pub.der")" -eq 44 ] || die "the baked-in public key is not 32 bytes"
  openssl pkey -pubin -inform DER -in "$TMP/pub.der" -out "$TMP/pub.pem" 2>/dev/null || die "cannot load the release public key"
  tr -d ' \n\r' <"$TMP/SHA256SUMS.sig" | base64 -d >"$TMP/sig.bin" 2>/dev/null || die "the signature file is not base64"
  openssl pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$TMP/SHA256SUMS" -sigfile "$TMP/sig.bin" >/dev/null 2>&1 \
    || die "SIGNATURE VERIFICATION FAILED for SHA256SUMS: refusing to install. The download was tampered with, or this installer does not match the release."
  say "Signature of SHA256SUMS verified."
  WANT_SUM="$(awk -v a="$ASSET" '$2==a || $2=="*"a {print $1; exit}' "$TMP/SHA256SUMS")"
  [[ "$WANT_SUM" =~ ^[0-9a-f]{64}$ ]] || die "$ASSET is not listed in the signed SHA256SUMS"
  fetch "$REL/$ASSET" "$TMP/$ASSET" || die "cannot download $REL/$ASSET"
  GOT_SUM="$(sha256sum "$TMP/$ASSET" | cut -d' ' -f1)"
  [ "$GOT_SUM" = "$WANT_SUM" ] || die "SHA-256 of $ASSET does not match the signed list (expected $WANT_SUM, got $GOT_SUM): refusing to install"
  say "SHA-256 of the archive verified."
  mkdir -p "$TMP/x"
  tar -xzf "$TMP/$ASSET" -C "$TMP/x" --no-same-owner
  SRC="$TMP/x/toutwaf-backup-linux-$ARCH"
  [ -x "$SRC/toutwaf-backup" ] || die "the archive does not contain toutwaf-backup"
  GOT_VER="$("$SRC/toutwaf-backup" version 2>/dev/null | sed -nE 's/^toutwaf-backup ([^ ]+).*/\1/p' || true)"
  [ "$GOT_VER" = "$WANT" ] || warn "the binary reports version '${GOT_VER:-?}', expected $WANT"
  mkdir -p "$BIN_DIR"
  if [ -f "$BIN" ]; then cp -p "$BIN" "$BIN.prev"; fi
  install -m 0755 "$SRC/toutwaf-backup" "$BIN.new.$$"
  mv -f "$BIN.new.$$" "$BIN"
  say "Installed $BIN ($WANT)."
  if [ -f "$BIN.prev" ] && [ -n "$CUR" ]; then say "Previous version $CUR kept as $BIN.prev (rollback: mv it back)."; fi
  UNIT_SRC="$SRC/systemd"
fi

# ---- roles --------------------------------------------------------------------------------------------------------------------
mkdir -p "$D$CONF_DIR"; chmod 0750 "$D$CONF_DIR"

if [ "$ROLE" = client ]; then
  say ""
  say "Client installed. Next steps:"
  say "  1. toutwaf-backup client init --server https://BACKUP-SERVER:8007 --tofu --token <token> --datastore <name> --create-key"
  say "  2. toutwaf-backup client backup --path /etc --id \$(hostname)"
  say "  3. toutwaf-backup client schedule --daily 02:30 --path /etc --path /var/www --install   (a systemd timer)"
  say "Keep the key file, its passphrase and the paper key OFF this machine too: without them a restore is impossible."
  exit 0
fi

# server role
if [ -z "$D" ]; then
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$STATE_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
      || adduser --system --home "$STATE_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" \
      || die "cannot create the user $SERVICE_USER"
    say "Created system user $SERVICE_USER."
  fi
fi
mkdir -p "$D$STATE_DIR"
if [ -z "$D" ]; then chown "$SERVICE_USER":"$SERVICE_USER" "$STATE_DIR"; fi
chmod 0750 "$D$STATE_DIR"

if [ "$NO_SYSTEMD" -eq 0 ] || [ -n "$D" ]; then
  mkdir -p "$UNIT_DIR"
  UNIT_TPL=""
  [ -n "${UNIT_SRC:-}" ] && [ -f "$UNIT_SRC/toutwaf-backup-server.service" ] && UNIT_TPL="$UNIT_SRC/toutwaf-backup-server.service"
  if [ -n "$UNIT_TPL" ]; then
    sed -e "s|@USER@|$SERVICE_USER|g" -e "s|@STATE@|$STATE_DIR|g" -e "s|@BIN@|$PREFIX/bin/toutwaf-backup|g" "$UNIT_TPL" >"$UNIT_DIR/toutwaf-backup-server.service.new"
    mv -f "$UNIT_DIR/toutwaf-backup-server.service.new" "$UNIT_DIR/toutwaf-backup-server.service"
    chmod 0644 "$UNIT_DIR/toutwaf-backup-server.service"
    say "Installed the systemd unit toutwaf-backup-server.service."
  elif [ ! -f "$UNIT_DIR/toutwaf-backup-server.service" ]; then
    warn "no unit template in the archive and none installed"
  fi
fi

FIRST=0
if [ "$INIT" -eq 1 ] && [ ! -f "$D$STATE_DIR/config.json" ]; then
  FIRST=1
  args=(server init --state "$D$STATE_DIR" --listen "$LISTEN")
  [ -z "$EXTERNAL_URL" ] || args+=(--external-url "$EXTERNAL_URL")
  [ -z "$DATASTORE" ] || args+=(--datastore "$DATASTORE")
  say ""
  say "First installation: creating the server configuration."
  if [ -z "$D" ]; then
    if command -v runuser >/dev/null 2>&1; then runuser -u "$SERVICE_USER" -- "$BIN" "${args[@]}"
    else su -s /bin/sh "$SERVICE_USER" -c "$(printf '%q ' "$BIN" "${args[@]}")"; fi
  else
    # staging: the binary may be for another CPU; only run it when it can run here
    if [ "$ARCH" = "$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" ]; then "$BIN" "${args[@]}"; fi
  fi
  say ""
  say "WRITE DOWN the admin token and the certificate fingerprint above: the token is not shown again."
fi

if use_systemd; then
  systemctl daemon-reload
  if [ "$START" -eq 1 ]; then
    systemctl enable --now toutwaf-backup-server.service
    say "Service enabled and started."
  elif systemctl is-active --quiet toutwaf-backup-server.service; then
    systemctl restart toutwaf-backup-server.service
    say "Service restarted on the new version."
  else
    say "Start it with: systemctl enable --now toutwaf-backup-server.service"
  fi
fi
port="${LISTEN##*:}"
say ""
say "Firewall: open TCP $port to your clients only, e.g."
if command -v ufw >/dev/null 2>&1; then say "  ufw allow from <client-network> to any port $port proto tcp"
elif command -v firewall-cmd >/dev/null 2>&1; then say "  firewall-cmd --permanent --add-port=$port/tcp && firewall-cmd --reload"
else say "  iptables -A INPUT -p tcp --dport $port -s <client-network> -j ACCEPT"; fi
[ "$FIRST" -eq 0 ] || say "Then: toutwaf-backup server --help   and open https://THIS-HOST:$port/ for the web interface."
exit 0
