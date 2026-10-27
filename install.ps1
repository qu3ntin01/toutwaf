#Requires -Version 5.1
<#
.SYNOPSIS
  ToutWAF installer for Windows (Windows 10 1809+ / 11, Windows Server 2016 / 2019 / 2022 / 2025; amd64 and arm64 (arm64 untested on real hardware); see -CheckCompat, -SkipOsCheck).

.EXAMPLE
  irm https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/main/install.ps1 | iex
  # interactive menu

.EXAMPLE
  & ([scriptblock]::Create((irm https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/main/install.ps1))) -Install -Yes -PublicHost waf.example.com
  # unattended "direct" install

.EXAMPLE
  & ([scriptblock]::Create((irm https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/main/install.ps1))) -Install -Component dp -CpUrl https://cp.example.com:9444 -EnrollToken XXXX -Yes

.DESCRIPTION
  Downloads the release, verifies its SHA-256 (and the cosign signature when cosign is installed), installs to
  %ProgramFiles%\ToutWAF, keeps configuration, data and logs in %ProgramData%\ToutWAF, registers the Windows services
  "ToutWAF" (data plane) and "toutwaf-cp" (control plane) with failure recovery, opens the firewall and starts them.
  Idempotent: re-running upgrades in place and rolls back if the new version does not become healthy. Existing
  configuration is never overwritten. At the end it prints the panel links, the generated administrator account,
  the one-time setup link and the ports to open (also saved to %ProgramData%\ToutWAF\INSTALL-SUMMARY.txt, Administrators only).

  Actions: -Install (default) -Update -Uninstall [-Purge] -Status -Links. Without any parameter, on a console, a menu is shown.
  Languages: -En -Fr -Es -De -It -Pt -Nl -Ru -Zh -Ar (or -Lang fr, or $env:TOUTWAF_LANG = 'fr') choose the installer language;
  by default it follows the Windows display language, English when that language is not supported.
  -ViaRepo: read the release from ToutWAF's own package repository for Windows first (index.json checked against its SHA-256); when it is
  unreachable or damaged the installer falls back to the project's GitLab, then GitHub, as without the switch. The archive is verified the same way.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Update,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Links,
    [string]$Version = 'latest',
    [ValidateSet('stable', 'dev', 'beta')][string]$Channel = '',
    [ValidateSet('dp', 'cp', 'all')][string]$Component = 'all',
    [string]$Repo = 'qu3ntin01/toutwaf',      # public binaries-only repository (deploy/RELEASE-LAYOUT.md)
    [string]$BaseUrl = '',
    [switch]$ViaRepo,                         # try ToutWAF's own package repository for Windows first (falls back to GitLab, then GitHub)
    [string]$ZipPath = '',
    [string[]]$ExtrasPath = @(),              # the extras of the release (Windows agents, antivirus programs) from local files: toutwaf-extras*.tar.gz (offline)
    [switch]$NoExtras,                       # do not download nor install the extras (also $env:TOUTWAF_NO_EXTRAS=1)
    [string]$CpUrl = '',
    [string]$EnrollToken = '',
    [string]$NodeToken = '',
    [string]$CpCa = '',
    [string]$Group = 'default',
    [ValidateRange(1, 65535)][int]$CpPort = 9443,
    [ValidateRange(1, 65535)][int]$HttpPort = 80,
    [ValidateRange(1, 65535)][int]$HttpsPort = 443,
    [string]$PublicHost = '',
    [switch]$OpenFirewall,
    [string]$ConsoleFrom = '',               # only this address / CIDR may reach the console port (default: anywhere)
    [switch]$NoFirewall,
    [switch]$NoTelemetry,                    # install with ZERO telemetry: nothing is sent to the publisher space (also $env:TOUTWAF_TELEMETRY=0)
    [switch]$NoStart,
    [switch]$NoEnable,
    [string]$InstallDir = '',
    [switch]$Force,
    [switch]$Purge,
    [string]$Lang = '',
    [switch]$En,
    [switch]$Fr,
    [switch]$Es,
    [switch]$De,
    [switch]$It,
    [switch]$Pt,
    [switch]$Nl,
    [switch]$Ru,
    [switch]$Zh,
    [switch]$Ar,
    [switch]$NoColor,
    [switch]$Quiet,
    [switch]$AcceptDefaults,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$SkipOsCheck,                     # install although this Windows version / architecture is not supported (warns, at your own risk)
    [switch]$CheckCompat                     # print the compatibility verdict and the supported versions, change nothing (exit 0 compatible, 3 not)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$script:InstallerVersion = '2'
$DefaultChannel = 'dev'   # the copy of this script published on the dev branch has: $DefaultChannel = 'dev'
$script:Bound = $PSBoundParameters
if (-not $InstallDir) { $InstallDir = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'ToutWAF' } else { 'C:\Program Files\ToutWAF' } }
if ($ConsoleFrom -and ($ConsoleFrom -notmatch '^[0-9a-fA-F:.]{2,45}(/[0-9]{1,3})?$' -or $ConsoleFrom -match '/0$')) { throw '-ConsoleFrom must be an address or a CIDR such as 203.0.113.0/24 (not 0.0.0.0/0)' }
$PdRoot = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
$DataRoot = Join-Path $PdRoot 'ToutWAF'
$ConfDir = Join-Path $DataRoot 'config'
$DataDir = Join-Path $DataRoot 'data'
$LogDir = Join-Path $DataRoot 'logs'
$CertsDir = Join-Path $DataDir 'certs'
$CpDataDir = Join-Path $DataDir 'controlplane'
$DpExe = Join-Path $InstallDir 'toutwaf-dp.exe'
$CpExe = Join-Path $InstallDir 'toutwaf-cp.exe'
$DpService = 'ToutWAF'
$CpService = 'toutwaf-cp'
$LogFile = Join-Path $DataRoot 'install.log'
$ConfFile = Join-Path $ConfDir 'installer.conf'

# Windows versions that are supported come from deploy/platforms.json (generated: edit it and run deploy/tools/gen-platforms.py).
# BEGIN PLATFORMS (generated by tools/gen-platforms.py)
$script:WinMinClient = 17763
$script:WinMinServer = 14393
$script:WinEditions = @(
    @{ Kind = 'client'; Name = 'Windows 11'; Build = 22000; Status = 'expected' }
    @{ Kind = 'client'; Name = 'Windows 10'; Build = 17763; Status = 'expected' }
    @{ Kind = 'server'; Name = 'Windows Server 2025'; Build = 26100; Status = 'expected' }
    @{ Kind = 'server'; Name = 'Windows Server 2022'; Build = 20348; Status = 'expected' }
    @{ Kind = 'server'; Name = 'Windows Server 2019'; Build = 17763; Status = 'expected' }
    @{ Kind = 'server'; Name = 'Windows Server 2016'; Build = 14393; Status = 'expected' }
)
$script:WinArchOk = @('amd64', 'arm64')
# END PLATFORMS

# ------------------------------------------------------------------------------------------------ message catalog
# 10 languages. Generated: edit deploy/tools/gen-installer-i18n.py, not these lines (ASCII only: \uXXXX escapes).
# BEGIN CATALOG (generated by tools/gen-installer-i18n.py)
$script:Catalog = @{
    'en' = @{
        'tagline' = 'Web application & API protection'
        'menu_title' = 'What would you like to do?'
        'opt_install' = 'Install (control plane + data plane + console)'
        'opt_install_d' = 'Everything on this machine: web console, policy store and reverse proxy / WAF.'
        'opt_cp' = 'Install the control plane only'
        'opt_cp_d' = 'Web console, API and policy store. Data planes (nodes) join it later.'
        'opt_dp' = 'Install a data plane only'
        'opt_dp_d' = 'Reverse proxy / WAF node that joins an existing control plane (asks for its URL and an enrolment token).'
        'opt_update' = 'Update'
        'opt_update_d' = 'Download a newer release, verify it (SHA-256 / sigstore), back up, keep configuration and data, roll back on failure.'
        'opt_uninstall' = 'Uninstall'
        'opt_uninstall_d' = 'Remove ToutWAF; you choose whether to keep or delete configuration, data and logs.'
        'opt_status' = 'Status and health check'
        'opt_status_d' = 'Installed versions, services, listening ports and health endpoints.'
        'opt_links' = 'Show the panel links again'
        'opt_links_d' = 'Panel URLs, one-time setup link and the firewall ports to open.'
        'opt_quit' = 'Quit'
        'choice' = 'Your choice'
        'invalid_choice' = 'Invalid choice.'
        'state_installed' = 'Installed: {0}'
        'state_none' = 'ToutWAF is not installed on this machine.'
        'cfg_title' = 'Installation options (Enter = default)'
        'q_cp_url' = 'Control plane URL (e.g. https://cp.example.com:9444)'
        'q_token' = 'Enrolment token (console: Nodes > Add node)'
        'q_cp_ca' = 'Control plane CA / certificate PEM file (empty = system trust store)'
        'q_cp_port' = 'Console port'
        'q_http_port' = 'HTTP port'
        'q_https_port' = 'HTTPS port'
        'q_public_host' = 'Public host name or IP address (empty = auto-detect)'
        'q_firewall' = 'Open the firewall automatically (firewalld / ufw)?'
        'q_boot' = 'Start the services at boot?'
        'q_channel' = 'Release channel (stable / dev)'
        'q_bindir' = 'Install directory'
        'q_confirm' = 'Proceed with the installation?'
        'q_purge' = 'Also delete configuration, data and logs? (No = keep them)'
        'q_confirm_un' = 'Really uninstall ToutWAF?'
        'aborted' = 'Aborted.'
        'root_required' = 'Run as root (sudo bash install.sh).'
        's_prereq' = 'Installing prerequisites'
        's_fetch' = 'Downloading ToutWAF {0} ({1})'
        's_sha' = 'SHA-256 verified'
        's_sig' = 'cosign signature verified'
        'w_nocosign' = 'cosign not installed: signature not verified (checksum only)'
        's_user' = 'Creating the service account and directories'
        's_bin' = 'Installing binaries'
        's_cfg' = 'Writing configuration (existing files are kept)'
        's_units' = 'Installing systemd units and system tuning'
        's_selinux' = 'Configuring SELinux'
        'q_console_from' = 'Only allow this network to reach the console (CIDR such as 203.0.113.0/24, empty = anyone)'
        'q_console_from_bad' = 'Not an address or CIDR (0.0.0.0/0 is the same as empty): the console port stays open to everyone.'
        'fw_console_note' = 'The console (port {0}) holds the administration login: opening it to the whole Internet is convenient but exposed.'
        'fw_console_open' = 'Console port {0} is open to everyone: restrict it with --console-from CIDR or in the console (Settings > Firewall)'
        'fw_console_from' = 'Console port {0} is only open to {1}'
        'fw_none' = 'No active firewall (firewalld / ufw / nftables / iptables) found: nothing filters the traffic, no port to open'
        'fw_manual' = 'The {0} firewall is not modified by the installer: run these commands yourself'
        'fw_failed' = 'The firewall could not be configured: {0}'
        'home_fresh' = 'New installation: everything goes under {0} (bin, conf, data, logs)'
        'home_legacy' = 'Existing installation detected: its paths are kept (bin {0}, conf {1}, data {2}). Nothing is moved; use --home DIR for the new layout.'
        'home_explicit_legacy' = '--home {0} was given while an installation exists in {1}: its data is NOT moved'
        'home_bad' = '--home must be an absolute path (letters, digits, . _ - + /), not / and not under /proc /sys /dev: {0}'
        'home_noexec' = '{0} is on a noexec mount: the binaries could not run from there, choose another --home'
        's_fw' = 'Configuring the firewall'
        's_boot' = 'Preparing the panel (administrator account, secure panel path)'
        's_start' = 'Starting the services'
        's_health' = 'Waiting for the services to become healthy'
        's_backup' = 'Backing up configuration and data'
        'w_rollback' = 'The new version is not healthy: rolling back to the previous one'
        'up_to_date' = 'Already up to date ({0})'
        'not_installed' = 'ToutWAF is not installed: nothing to update.'
        'st_channel' = 'Channel: {0}'
        'st_latest' = 'Latest available: {0}'
        'st_newer' = 'update available: run with --update'
        'e_yanked' = 'Version {0} was withdrawn (yanked) and must not be installed. Run --update for the current release, or --force to override.'
        'e_nover' = 'No version is published on the {0} channel yet, so there is nothing to install. ToutWAF was not installed or modified. To install from the {1} channel instead, run the installer again with -Channel {2}.'
        'e_installer_old' = 'This installer is too old for this release (needs version {0}): download it again from the channel URL.'
        'up_rebuilt' = 'Same version, new build: installed {0}, available {1}. Updating.'
        'st_newbuild' = 'same version, new build available: run again with {0}'
        'st_nochannel' = 'Latest available: nothing published on this channel yet'
        'w_mirror' = 'The public mirror served files that do not agree with each other ({0}): it is probably still refreshing after a publication. Reading the channel again, once.'
        'e_mismatch' = 'checksum mismatch for {0} ({1}): the downloaded file does not match the checksum that was published, so nothing was installed or changed. Right after a publication the public mirror can serve the previous files for a few minutes: wait five minutes and run the installer again. If it happens again, do not install: the publication is damaged.'
        'e_downgrade' = 'The latest release {0} of channel {1} is older than the installed {2}: use --force to downgrade.'
        's_sigok' = 'release signature verified, key {0}'
        'w_sigold' = 'release {0} was published without a signature (releases before 0.2.0-dev.7 are unsigned): only SHA-256 was verified, the signature could not be checked'
        'w_sigskip' = 'release signature NOT verified: openssl.exe was not found in PATH (Windows has no built-in Ed25519 verification), only SHA-256 was checked. Install OpenSSL 3 and run again to verify against key {0}'
        'done' = 'Done.'
        'failed' = 'Failed'
        'log_hint' = 'Full log: {0}'
        'dry_done' = 'Dry run: nothing was changed.'
        'sum_title' = 'Installation summary'
        'sum_panel' = 'Panel links'
        'sum_tls_note' = 'HTTPS only. The certificate is self-signed until you install your own: the browser will show a warning.'
        'sum_local' = 'Local addresses'
        'sum_public' = 'Public address'
        'sum_public_unknown' = 'The public IP address could not be detected (offline or blocked). Use your server''s public IP or DNS name instead of the local addresses, or re-run with --public-host.'
        'sum_admin' = 'Administrator account'
        'sum_user' = 'Username'
        'sum_password' = 'Password'
        'sum_pw_once' = 'shown ONCE only - change it in Settings > Access / Account'
        'sum_pw_unchanged' = 'unchanged (never regenerated). Reset it with: toutwaf-cp admin reset-password --user {0}'
        'sum_setup' = 'One-time setup link'
        'sum_setup_note' = 'Open it to configure the panel link, the account and the password in the web installer.'
        'p_dpapi_warn' = 'Port 9444 (data-plane API) is NOT opened: allow it only from your data-plane nodes'
        'p_dpapi_only' = '9444/tcp only from your data planes, e.g.:'
        'sum_setup_none' = 'No setup link this time (already issued, or the account already existed). Create a new one with: toutwaf-cp setup-link --regenerate'
        'sum_ports' = 'Ports to open in the firewall'
        'sum_cmds' = 'Commands'
        'sum_cloud' = 'Cloud / hosting: also open these ports in the provider''s security group / network ACL.'
        'sum_file' = 'Summary saved (root only): {0}'
        'sum_fallback' = 'This control plane has no ''bootstrap'' command yet: open the console URL and follow the setup page.'
        'sum_node_hint' = 'To manage this node from the console: Nodes > Add node, then set control_plane.url / enroll_token in {0}.'
        'q_fwmodule' = 'Do you also want ToutWAF to manage this machine''s firewall?'
        'fwmod_n1' = 'Optional module, off unless you say yes. Nothing is applied during the installation: you review every change in the console.'
        's_bkclient' = 'Installing the ToutWAF Backup client (signature checked)'
        'bkc_done' = 'ToutWAF Backup client installed. Next: console, Backups > Backup servers, to pair a backup server.'
        'bkc_fail' = 'The ToutWAF Backup client was NOT installed ({0}). The installation goes on; install it later with --with-backup-client.'
        'bkc_nokey' = 'The ToutWAF Backup client was NOT installed: no release public key. Give it with --backup-client-pubkey (or TOUTWAF_BACKUP_PUBKEY, or the file backup-release.pub in the configuration folder); nothing is installed without a verified signature.'
        'bkc_badsig' = 'The ToutWAF Backup client was NOT installed: the signature of the release is NOT valid. Nothing was installed.'
        'tele_on' = 'Telemetry: by default ToutWAF shares with the publisher space (app.toutwaf.com) the attacks it blocked (attacker address, country, type of attack, rule) and aggregate figures, and the host names of the protected sites. Never the content of requests, never legitimate visitors. Switch it off in one click in the console (Settings, Privacy and telemetry), or install with --no-telemetry (or TOUTWAF_TELEMETRY=0) for zero telemetry. Details: docs/confidentialite-telemetrie.md'
        'tele_off' = 'Telemetry: zero telemetry was requested (--no-telemetry / TOUTWAF_TELEMETRY=0). Nothing will be sent to the publisher space, nothing will be received from it, and the console starts with the "Zero telemetry" switch on. You can change this later in the console (Settings, Privacy and telemetry).'
        'fwmod_n2' = 'Every change runs as a trial with a countdown and rolls back by itself unless you keep it; an anti-lockout guard refuses any rule that would cut SSH or the console.'
        'fwmod_n3' = 'This is not the question above, which only opens the ports ToutWAF needs in the system firewall (--no-firewall).'
        's_fwmod' = 'Enabling the firewall module (no rule applied)'
        'fwmod_done' = 'Firewall module enabled. Nothing was applied: open Firewall in the console to review and try rules.'
        'fwmod_fail' = 'Could not enable the firewall module ({0}). The installation goes on; switch it on later in Settings > Modules.'
        's_link' = 'Linking the data plane to the console'
        'dp_link_ok' = 'Data plane linked to the console automatically: nothing to configure by hand.'
        'dp_link_same' = 'Data plane already linked to the console; its configuration was not touched.'
        'dp_link_fixed' = 'Data-plane configuration repaired (duplicated control_plane blocks merged into one); the previous file was kept.'
        'dp_link_remote' = 'The data plane on this machine is configured for another console; it was left unchanged.'
        'dp_link_fail' = 'The data plane could not be linked to the console automatically: {0}'
        'dp_link_fail_hint' = 'The data plane keeps its standalone configuration, so sites answer HTTP 421 until it is linked. Fix the cause above and run this installer again: it links the node by itself.'
        'st_title' = 'Status'
        'st_healthy' = 'healthy'
        'st_unhealthy' = 'NOT healthy'
        'st_active' = 'active'
        'st_inactive' = 'inactive'
        'st_listening' = 'listening'
        'st_closed' = 'not listening'
        'un_title' = 'Uninstalling ToutWAF'
        'un_kept' = 'Configuration kept in {0}, data in {1} (use --purge to delete).'
        'un_purged' = 'Configuration, data and logs deleted.'
        'p_console' = 'web console + API'
        'p_http' = 'HTTP (reverse proxy)'
        'p_https' = 'HTTPS (reverse proxy)'
        'p_dpapi' = 'data-plane API: ONLY if data planes run on OTHER hosts (restrict to their IPs)'
        'w_fw_manual' = 'Port {0}/tcp was not opened automatically: see the commands in the summary.'
        'need_cp' = 'A control plane URL is required when an enrolment token is given.'
        'cp_title' = 'System compatibility'
        'cp_detected' = 'Detected: {0}, arch {1}, glibc {2}, systemd {3}, kernel {4}'
        'cp_ok' = 'Compatible: {0} ({1})'
        'cp_tested' = 'tested'
        'cp_expected' = 'expected'
        'cp_w_like' = '{0} is not in the compatibility table: treated as the {1} family (expected). Continuing.'
        'cp_w_newer' = '{0} {1} is newer than the listed versions: not validated yet (expected). Continuing.'
        'cp_w_unlisted' = '{0} {1} is not listed in the table: treated as expected. Continuing.'
        'cp_w_nover' = '{0} reports no version (rolling or testing release): treated as expected. Continuing.'
        'cp_w_glibc' = 'The glibc version could not be determined; continuing.'
        'cp_w_skip' = '--skip-os-check: the compatibility check is bypassed. This system is NOT supported: continuing at your own risk.'
        'cp_w_stage' = 'Staging (--destdir): the compatibility verdict is informational only, nothing is refused.'
        'cp_refused' = 'This system is not compatible with ToutWAF:'
        'cp_r_old' = '{0} {1} is older than the minimum supported version ({2}).'
        'cp_r_eol' = '{0} {1} is end of life, or its glibc / systemd is too old.'
        'cp_r_glibc' = 'glibc {0} found: {1} or newer is required.'
        'cp_r_musl' = 'musl libc found: glibc {0} or newer is required.'
        'cp_r_init' = '{0} {1} does not use systemd, which ToutWAF requires.'
        'cp_r_immutable' = '{0} {1} has an immutable root filesystem (not supported).'
        'cp_r_layout' = '{0} {1} does not follow the standard Linux filesystem layout (not supported).'
        'cp_r_arch' = 'Architecture {0} is not supported (supported: {1}).'
        'cp_r_distro_arch' = '{0} {1} runs on an architecture without a ToutWAF build.'
        'cp_r_systemd' = 'systemd is not running as the init system (/run/systemd/system is missing): it is required for the services.'
        'cp_r_systemd_old' = 'systemd {0} found: {1} or newer is required.'
        'cp_r_kernel' = 'Linux kernel {0} found: {1} or newer is required.'
        'cp_r_unknown' = 'Distribution ''{0}'' is not recognised and declares no known family (ID_LIKE=''{1}'').'
        'cp_r_noosr' = '/etc/os-release is missing: the distribution cannot be identified.'
        'cp_nochange' = 'Nothing has been changed on this system.'
        'cp_list' = 'Compatible systems (amd64 and arm64, glibc {0} or newer, systemd {1} or newer):'
        'cp_rolling' = 'rolling'
        'cp_any' = 'any version'
        'cp_override' = 'To install anyway, at your own risk: --skip-os-check. Details: docs/install/platforms.md'
        'cp_not_root' = 'Not running as root: use sudo to install (the check itself does not need root).'
        'sum_compat' = 'Compatibility'
        'cp_prereq_arch' = 'The package databases are not synchronised. Run ''pacman -Syu'' first (a partial upgrade is not supported on Arch), then re-run the installer.'
        'cp_wdetected' = 'Detected: {0} (build {1}), arch {2}'
        'cp_wlist' = 'Compatible Windows versions (amd64 and arm64; arm64 untested on real hardware):'
        'cp_r_arm32' = '32-bit ARM (armv7) is not supported by ToutWAF. Install a 64-bit OS (Raspberry Pi OS 64-bit, Ubuntu or Debian arm64; Raspberry Pi 3, 4, 5 or Zero 2 W), then run the installer again.'
        'cp_r_arm_userland32' = 'The kernel is 64-bit but the system (userland) is 32-bit. ToutWAF needs a 64-bit OS: reinstall with Raspberry Pi OS 64-bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) or Ubuntu / Debian arm64.'
        'cp_w_pi' = 'Raspberry Pi detected: arm64 is only smoke-tested under emulation, not on real hardware. Put the data and logs on an SSD / USB drive rather than the SD card, and avoid the all-in-one install below 2 GB of RAM (see docs/install/raspberry-pi.md).'
        'pf_title' = 'Checking what this machine needs'
        'pf_ok' = 'Nothing is in the way: the ports ToutWAF needs are free.'
        'pf_refused' = 'ToutWAF cannot be installed on this machine as it is. Nothing was changed.'
        'pf_ok_warn' = 'Nothing prevents the installation, but read the points above.'
        'pf_l_refuse' = 'refused'
        'pf_l_warn' = 'warning'
        'pf_l_info' = 'note'
        'pf_port_busy' = 'Port {0} is already used by {1}.'
        'pf_prog_other' = 'another program'
        'pf_prog_unknown' = 'another program (its name could not be read)'
        'pf_act_web' = 'ToutWAF needs ports {0} and {1} to protect your sites. Stop that program, or move it to other ports (ToutPanel, installed beside ToutWAF, places its web server on 8080 and 8443), then run the installer again.'
        'pf_act_console' = 'The console of ToutWAF needs this port. Free it, or choose another console port (the installer asks for it in its menu), then run the installer again.'
        'pf_act_agent' = 'ToutWAF uses this port for the data planes and agents that connect to it. Free it, then run the installer again.'
        'pf_act_admin' = 'The data plane uses this port on this machine only, for its own health check. Free it, then run the installer again.'
        'pf_nostart' = '(nothing is started now, so this is only reported)'
        'pf_boot' = '{0} is installed and starts with the machine, although it is stopped now. After the next restart it would take ports {1} and {2} before ToutWAF.'
        'pf_act_boot' = 'Disable it so that it does not start with the machine, or move it to other ports, before the machine restarts.'
        'pf_fw_cause' = 'A firewall ({0}) is active and does not let ports {1} and {2} through, and the installer was told not to change it.'
        'pf_fw_action' = 'Open these ports in the firewall, or let the installer do it (do not use --no-firewall). Without that, your sites cannot be reached from outside.'
        'pf_fwx_cause' = 'The firewall of this machine ({0}) refuses incoming connections by default and has no rule for ports {1} and {2}.'
        'pf_fwx_action' = 'ToutWAF never changes the rules of this kind of firewall itself: open these ports in its configuration, then check your sites.'
        'pf_cp_cause' = 'The control plane {0} cannot be reached from this machine.'
        'pf_cp_action' = 'Check the address, that the control plane is running, and that its firewall lets this machine reach it (port 9444 by default), then run the installer again.'
        'pf_router_cause' = 'This machine has a private address ({0}): it is probably behind a router or a box.'
        'pf_router_action' = 'Once installed, ToutWAF shows which ports to forward to this machine and gives the files for the usual routers. There is nothing to prepare now.'
        'pf_skipped' = 'The environment check was skipped as you asked: what is in the way will make the installation or the start fail later.'
        's_sysupdate' = 'Updating the system packages (this can take several minutes)'
        'su_skipped' = 'The system packages are not updated first (TOUTWAF_SKIP_SYSUPDATE).'
        'su_recent' = 'The system packages were updated less than 6 hours ago: not repeated.'
        'su_dry' = 'the system packages would be updated first (skip it with TOUTWAF_SKIP_SYSUPDATE=1)'
        'su_nopm' = 'No supported package manager to update the system packages: skipped, the installation goes on.'
        'su_failed' = 'The update of the system packages failed (exit {0}); the installation goes on without it. Details: {1}. Fix: run the update yourself and read its error (broken repository? another package manager running?), or run this command again with TOUTWAF_SKIP_SYSUPDATE=1.'
        'su_reboot' = 'A restart of this server is needed to finish the system update (new kernel or libraries). ToutWAF never restarts it for you: do it when you can.'
        'q_sysupdate' = 'Update the system packages first (recommended)?'
        'pr_disk_full' = 'Only {0} MB are free on {1} (at least {2} MB are needed): the installation could not finish.'
        'pr_disk_full_a' = 'Free some space (package cache: apt-get clean or dnf clean all; old logs: journalctl --vacuum-size=100M), then run this command again. To go on anyway: TOUTWAF_SKIP_PREREQ=1.'
        'pr_disk_full_w_a' = 'Free some space (Disk Cleanup, empty the recycle bin), then run this command again. To go on anyway: $env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = 'Only {0} MB are free on {1} (about {2} MB are comfortable).'
        'pr_disk_low_a' = 'Free some space or add disk space; the installation can go on.'
        'pr_dns' = 'This machine cannot resolve the name {0} (DNS).'
        'pr_dns_a' = 'Check the DNS servers (cat /etc/resolv.conf, resolvectl status), add a working one such as nameserver 9.9.9.9, then run this command again.'
        'pr_dns_w_a' = 'Check the DNS servers with ''ipconfig /all'', set a working one (for example 9.9.9.9) in the network adapter settings, then run this command again.'
        'pr_clock' = 'The clock of this machine is {0} seconds away from the Internet time: TLS certificates and signatures fail when the clock is wrong.'
        'pr_clock_a' = 'Synchronise it: timedatectl set-ntp true (or chronyc makestep), check with timedatectl, then run this command again.'
        'pr_clock_w_a' = 'Synchronise it: w32tm /resync (or Settings > Time and language > Sync now), then run this command again.'
        'pr_ok' = 'Disk space, DNS and the clock are fine.'
        'cloud_https' = '--cloud-url must be an https:// address (the node never talks to the cloud in clear).'
        'cloud_dp_only' = '--cloud-url installs a protection node: use it with --component dp (the default in cloud mode).'
        'cloud_need_token' = 'An enrolment token is required to connect this node to your account (--enroll-token; console: Nodes > Add my first node).'
        'cloud_ca_local' = '--cloud-ca must be a local file.'
        'cloud_nolink' = 'This release does not contain the ToutWAF Cloud link (toutwaf-cloudlink): update the installer or use a newer release.'
        'cloud_enrol_failed' = 'The node could not be enrolled with your account (see the lines above). The token may be used or expired: create a new one in the console.'
        'pf_cloud_action' = 'Allow this machine to reach your ToutWAF Cloud address on port 443 (outbound only), or set HTTPS_PROXY if a proxy is required. Nothing needs to be opened for inbound traffic.'
        's_db' = 'Preparing the database'
        'db_choose' = 'Which database should ToutWAF use?'
        'db_opt_pg' = 'PostgreSQL (recommended)'
        'db_opt_pg_local' = 'Install PostgreSQL on this machine (created and configured for you)'
        'db_opt_pg_remote' = 'Use an existing PostgreSQL server (tested, then prepared if you allow it)'
        'db_opt_sqlite' = 'SQLite (small installation, one server only)'
        'db_sqlite_note' = 'SQLite is one file on this machine: fine for a small installation on one server. It cannot be shared by several control planes and has no replication. You can move to PostgreSQL later with: toutwaf-cp db migrate.'
        'db_q_host' = 'PostgreSQL host'
        'db_q_port' = 'Port'
        'db_q_name' = 'Database name'
        'db_q_user' = 'Database user'
        'db_q_pw' = 'Password of that user (empty if an administrator account creates it)'
        'db_q_tls' = 'TLS mode (disable, prefer, require, verify-ca, verify-full)'
        'db_q_ca' = 'CA certificate file of the server (for verify-ca / verify-full)'
        'db_q_admin' = 'Administrator account that creates the user and the database (empty = they already exist)'
        'db_q_adminpw' = 'Password of the administrator account (used once, never stored)'
        'db_hint' = 'Database: SQLite (default). For a server install or several control planes use --db postgres (--db-install-local installs it for you).'
        'db_no_pkg' = 'PostgreSQL cannot be installed automatically on this system: install the server package yourself, then run the installer again with --db postgres.'
        'db_install_failed' = 'Installing the PostgreSQL package failed. The log says why (/var/log/toutwaf-install.log).'
        'db_init_failed' = 'The PostgreSQL cluster could not be initialised. The log says why.'
        'db_start_failed' = 'PostgreSQL does not start. Check: systemctl status postgresql, and the log.'
        'db_too_old' = 'The PostgreSQL version installed here ({0}) is too old: version 13 or newer is required.'
        'db_exists' = 'A database user "{0}" or a database "{1}" already exists and was not created by this installer: nothing was changed. Choose other names (--db-name, --db-user) or give the existing connection (--db-dsn-file).'
        'db_create_failed' = 'The user or the database could not be created. What was created was removed again.'
        'db_rights' = 'The account is not allowed to do this. The statements above are the minimum an administrator of the server has to run; then run the installer again.'
        'db_need_conn' = 'No connection to the PostgreSQL server was given: use --db-dsn-file, or --db-host with --db-password-file, or --db-install-local.'
        'db_schema_failed' = 'The tables could not be created in the database. The log says why.'
        'db_no_pgdump' = 'pg_dump is missing: the daily database backup will report an error until the PostgreSQL client package is installed.'
        'db_sum_engine' = 'Database: {0}'
        'db_sum_local' = 'PostgreSQL runs on this machine (loopback only); database {0}, user {1} (no administrator rights)'
        'db_sum_remote' = 'Existing PostgreSQL server; database {0}, user {1}'
        'db_sum_schema' = 'Schema: {0}'
        'db_sum_secret' = 'The connection (with its password) is in {0}, readable by the ToutWAF service only'
        'db_sum_backup' = 'A verified pg_dump runs every night (7 kept); status in the console, Sant\u00e9'
        'db_sum_nobackup' = 'No automatic database backup: schedule pg_dump or use the backup of your database provider'
        'db_sum_sqlite' = 'Database: SQLite, one file on this machine (small installation). Move to PostgreSQL later: toutwaf-cp db migrate'
        's_extras' = 'Extras: Windows agent and antivirus programs'
        's_extras_ok' = 'Extras installed: {0} programs in {1}'
        's_extras_sha' = 'Extras verified: {0} file(s), {1} MiB (SHA-256 and signature)'
        's_extras_unchecked' = 'Extras taken as given, without a SHA256SUMS to check them: {0}'
        'w_extras_dl' = 'The extras could not be downloaded ({0}). ToutWAF works without them, but this console will not offer Windows nor the antivirus until they are installed.'
        'w_extras_sum' = 'The extras {0} do not match their SHA-256 in the signed SHA256SUMS: they were NOT installed.'
        'w_extras_bad' = 'The extras file {0} is not a valid extras archive: it was NOT installed.'
        'w_extras_ver' = 'The extras are for version {0}, this installation is {1}: they were NOT installed.'
        'w_extras_inc' = 'The release lists {0} part(s) of the extras but says it has {1}: the publication is damaged, the extras were NOT installed.'
        'w_extras_nofile' = 'The extras file {0} does not exist.'
        'w_extras_none' = 'This release carries no extras: this console will not offer Windows nor the antivirus.'
        'w_extras_todo' = 'Extras not installed. When the network allows it, run as root: {0}'
        'extras_needs_cp' = 'The extras belong to the control plane: it is not installed on this machine.'
        'extras_other_release' = 'The published release ({0}) is not the installed one ({1}): the extras come with it. Run --update.'
        'st_extras_ok' = 'Extras: installed (Windows agent, antivirus programs)'
        'st_extras_none' = 'Extras missing: Windows and the antivirus are not offered. Run as root: {0}'
    }
    'fr' = @{
        'tagline' = 'Protection des applications web et des API'
        'menu_title' = 'Que souhaitez-vous faire ?'
        'opt_install' = 'Installer (plan de contr\u00f4le + plan de donn\u00e9es + console)'
        'opt_install_d' = 'Tout sur cette machine : console web, base de politiques et reverse proxy / WAF.'
        'opt_cp' = 'Installer le plan de contr\u00f4le seul'
        'opt_cp_d' = 'Console web, API et base de politiques. Les plans de donn\u00e9es (n\u0153uds) la rejoignent ensuite.'
        'opt_dp' = 'Installer un plan de donn\u00e9es seul'
        'opt_dp_d' = 'N\u0153ud reverse proxy / WAF qui rejoint un plan de contr\u00f4le existant (demande son URL et un jeton d''enr\u00f4lement).'
        'opt_update' = 'Mettre \u00e0 jour'
        'opt_update_d' = 'T\u00e9l\u00e9charge une version plus r\u00e9cente, la v\u00e9rifie (SHA-256 / sigstore), sauvegarde, conserve configuration et donn\u00e9es, annule en cas d''\u00e9chec.'
        'opt_uninstall' = 'D\u00e9sinstaller'
        'opt_uninstall_d' = 'Supprime ToutWAF ; vous choisissez de conserver ou de supprimer configuration, donn\u00e9es et journaux.'
        'opt_status' = '\u00c9tat et v\u00e9rification de sant\u00e9'
        'opt_status_d' = 'Versions install\u00e9es, services, ports en \u00e9coute et points de sant\u00e9.'
        'opt_links' = 'Afficher \u00e0 nouveau les liens du panneau'
        'opt_links_d' = 'URL du panneau, lien d''installation \u00e0 usage unique et ports \u00e0 ouvrir dans le pare-feu.'
        'opt_quit' = 'Quitter'
        'choice' = 'Votre choix'
        'invalid_choice' = 'Choix invalide.'
        'state_installed' = 'Install\u00e9 : {0}'
        'state_none' = 'ToutWAF n''est pas install\u00e9 sur cette machine.'
        'cfg_title' = 'Options d''installation (Entr\u00e9e = valeur par d\u00e9faut)'
        'q_cp_url' = 'URL du plan de contr\u00f4le (ex. https://cp.example.com:9444)'
        'q_token' = 'Jeton d''enr\u00f4lement (console : N\u0153uds > Ajouter un n\u0153ud)'
        'q_cp_ca' = 'Fichier PEM de la CA / du certificat du plan de contr\u00f4le (vide = magasin syst\u00e8me)'
        'q_cp_port' = 'Port de la console'
        'q_http_port' = 'Port HTTP'
        'q_https_port' = 'Port HTTPS'
        'q_public_host' = 'Nom d''h\u00f4te ou adresse IP publique (vide = d\u00e9tection auto)'
        'q_firewall' = 'Ouvrir automatiquement le pare-feu (firewalld / ufw) ?'
        'q_boot' = 'D\u00e9marrer les services au d\u00e9marrage ?'
        'q_channel' = 'Canal de publication (stable / dev)'
        'q_bindir' = 'R\u00e9pertoire d''installation'
        'q_confirm' = 'Lancer l''installation ?'
        'q_purge' = 'Supprimer aussi configuration, donn\u00e9es et journaux ? (Non = les conserver)'
        'q_confirm_un' = 'D\u00e9sinstaller vraiment ToutWAF ?'
        'aborted' = 'Abandon.'
        'root_required' = 'Ex\u00e9cutez en root (sudo bash install.sh).'
        's_prereq' = 'Installation des pr\u00e9requis'
        's_fetch' = 'T\u00e9l\u00e9chargement de ToutWAF {0} ({1})'
        's_sha' = 'SHA-256 v\u00e9rifi\u00e9'
        's_sig' = 'Signature cosign v\u00e9rifi\u00e9e'
        'w_nocosign' = 'cosign absent : signature non v\u00e9rifi\u00e9e (somme de contr\u00f4le uniquement)'
        's_user' = 'Cr\u00e9ation du compte de service et des r\u00e9pertoires'
        's_bin' = 'Installation des binaires'
        's_cfg' = '\u00c9criture de la configuration (les fichiers existants sont conserv\u00e9s)'
        's_units' = 'Installation des unit\u00e9s systemd et r\u00e9glages syst\u00e8me'
        's_selinux' = 'Configuration de SELinux'
        'q_console_from' = 'N''autoriser que ce r\u00e9seau \u00e0 joindre la console (CIDR, ex. 203.0.113.0/24 ; vide = tout le monde)'
        'q_console_from_bad' = 'Ni adresse ni CIDR valide (0.0.0.0/0 revient \u00e0 vide) : le port de la console reste ouvert \u00e0 tous.'
        'fw_console_note' = 'La console (port {0}) porte la connexion d''administration : l''ouvrir \u00e0 tout Internet est pratique mais expos\u00e9.'
        'fw_console_open' = 'Le port {0} de la console est ouvert \u00e0 tous : restreignez-le avec --console-from CIDR ou dans la console (R\u00e9glages > Pare-feu)'
        'fw_console_from' = 'Le port {0} de la console n''est ouvert qu''\u00e0 {1}'
        'fw_none' = 'Aucun pare-feu actif (firewalld / ufw / nftables / iptables) : rien ne filtre le trafic, aucun port \u00e0 ouvrir'
        'fw_manual' = 'Le pare-feu {0} n''est pas modifi\u00e9 par l''installeur : ex\u00e9cutez vous-m\u00eame ces commandes'
        'fw_failed' = 'Le pare-feu n''a pas pu \u00eatre configur\u00e9 : {0}'
        'home_fresh' = 'Nouvelle installation : tout est plac\u00e9 sous {0} (bin, conf, data, logs)'
        'home_legacy' = 'Installation existante d\u00e9tect\u00e9e : ses chemins sont conserv\u00e9s (bin {0}, conf {1}, data {2}). Rien n''est d\u00e9plac\u00e9 ; utilisez --home DIR pour la nouvelle disposition.'
        'home_explicit_legacy' = '--home {0} a \u00e9t\u00e9 donn\u00e9 alors qu''une installation existe dans {1} : ses donn\u00e9es ne sont PAS d\u00e9plac\u00e9es'
        'home_bad' = '--home doit \u00eatre un chemin absolu (lettres, chiffres, . _ - + /), ni / ni sous /proc /sys /dev : {0}'
        'home_noexec' = '{0} est sur un montage noexec : les binaires n''y pourraient pas s''ex\u00e9cuter, choisissez un autre --home'
        's_fw' = 'Configuration du pare-feu'
        's_boot' = 'Pr\u00e9paration du panneau (compte administrateur, chemin s\u00e9curis\u00e9)'
        's_start' = 'D\u00e9marrage des services'
        's_health' = 'Attente de la disponibilit\u00e9 des services'
        's_backup' = 'Sauvegarde de la configuration et des donn\u00e9es'
        'w_rollback' = 'La nouvelle version n''est pas saine : retour \u00e0 la pr\u00e9c\u00e9dente'
        'up_to_date' = 'D\u00e9j\u00e0 \u00e0 jour ({0})'
        'not_installed' = 'ToutWAF n''est pas install\u00e9 : rien \u00e0 mettre \u00e0 jour.'
        'st_channel' = 'Canal : {0}'
        'st_latest' = 'Derni\u00e8re version disponible : {0}'
        'st_newer' = 'mise \u00e0 jour disponible : lancez avec --update'
        'e_yanked' = 'La version {0} a \u00e9t\u00e9 retir\u00e9e (yanked) et ne doit pas \u00eatre install\u00e9e. Lancez --update pour la version courante, ou --force pour passer outre.'
        'e_nover' = 'Aucune version n''est encore publi\u00e9e sur le canal {0} : il n''y a rien \u00e0 installer. ToutWAF n''a \u00e9t\u00e9 ni install\u00e9 ni modifi\u00e9. Pour installer depuis le canal {1}, relancez l''installeur avec -Channel {2}.'
        'e_installer_old' = 'Cet installeur est trop ancien pour cette version (version {0} requise) : ret\u00e9l\u00e9chargez-le depuis l''URL du canal.'
        'up_rebuilt' = 'M\u00eame version, nouvelle compilation : install\u00e9e {0}, disponible {1}. Mise \u00e0 jour en cours.'
        'st_newbuild' = 'm\u00eame version, nouvelle compilation disponible : relancez avec {0}'
        'st_nochannel' = 'Derni\u00e8re version disponible : rien n''est encore publi\u00e9 sur ce canal'
        'w_mirror' = 'Le miroir public a servi des fichiers qui ne concordent pas ({0}) : il est probablement encore en cours de mise \u00e0 jour apr\u00e8s une publication. Nouvelle lecture du canal, une seule fois.'
        'e_mismatch' = 'somme de contr\u00f4le incorrecte pour {0} ({1}) : le fichier t\u00e9l\u00e9charg\u00e9 ne correspond pas \u00e0 la somme publi\u00e9e, donc rien n''a \u00e9t\u00e9 install\u00e9 ni modifi\u00e9. Juste apr\u00e8s une publication, le miroir public peut servir les anciens fichiers pendant quelques minutes : attendez cinq minutes et relancez l''installeur. Si cela se reproduit, n''installez pas : la publication est endommag\u00e9e.'
        'e_downgrade' = 'La derni\u00e8re version {0} du canal {1} est plus ancienne que la version install\u00e9e {2} : utilisez --force pour r\u00e9trograder.'
        's_sigok' = 'signature de la version v\u00e9rifi\u00e9e, cl\u00e9 {0}'
        'w_sigold' = 'la version {0} a \u00e9t\u00e9 publi\u00e9e sans signature (les versions ant\u00e9rieures \u00e0 0.2.0-dev.7 ne sont pas sign\u00e9es) : seul le SHA-256 a \u00e9t\u00e9 v\u00e9rifi\u00e9, la signature n''a pas pu l''\u00eatre'
        'w_sigskip' = 'signature de la version NON v\u00e9rifi\u00e9e : openssl.exe est introuvable dans le PATH (Windows n''a pas de v\u00e9rification Ed25519 int\u00e9gr\u00e9e), seul le SHA-256 a \u00e9t\u00e9 contr\u00f4l\u00e9. Installez OpenSSL 3 et relancez pour v\u00e9rifier avec la cl\u00e9 {0}'
        'done' = 'Termin\u00e9.'
        'failed' = '\u00c9chec'
        'log_hint' = 'Journal complet : {0}'
        'dry_done' = 'Simulation : rien n''a \u00e9t\u00e9 modifi\u00e9.'
        'sum_title' = 'R\u00e9capitulatif de l''installation'
        'sum_panel' = 'Liens du panneau'
        'sum_tls_note' = 'HTTPS uniquement. Le certificat est auto-sign\u00e9 tant que vous n''installez pas le v\u00f4tre : le navigateur affichera un avertissement.'
        'sum_local' = 'Adresses locales'
        'sum_public' = 'Adresse publique'
        'sum_public_unknown' = 'L''adresse IP publique n''a pas pu \u00eatre d\u00e9tect\u00e9e (hors ligne ou bloqu\u00e9e). Utilisez l''IP publique ou le nom DNS de votre serveur \u00e0 la place des adresses locales, ou relancez avec --public-host.'
        'sum_admin' = 'Compte administrateur'
        'sum_user' = 'Identifiant'
        'sum_password' = 'Mot de passe'
        'sum_pw_once' = 'affich\u00e9 UNE SEULE fois - modifiable dans R\u00e9glages > Acc\u00e8s / Compte'
        'sum_pw_unchanged' = 'inchang\u00e9 (jamais r\u00e9g\u00e9n\u00e9r\u00e9). R\u00e9initialisez-le avec : toutwaf-cp admin reset-password --user {0}'
        'sum_setup' = 'Lien d''installation \u00e0 usage unique'
        'sum_setup_note' = 'Ouvrez-le pour configurer le lien du panneau, le compte et le mot de passe dans l''assistant web.'
        'p_dpapi_warn' = 'Le port 9444 (API data plane) n''est PAS ouvert : autorisez-le uniquement depuis vos n\u0153uds data plane'
        'p_dpapi_only' = '9444/tcp uniquement depuis vos data planes, par ex. :'
        'sum_setup_none' = 'Pas de lien d''installation cette fois (d\u00e9j\u00e0 \u00e9mis, ou compte d\u00e9j\u00e0 existant). Pour en cr\u00e9er un : toutwaf-cp setup-link --regenerate'
        'sum_ports' = 'Ports \u00e0 ouvrir dans le pare-feu'
        'sum_cmds' = 'Commandes'
        'sum_cloud' = 'Cloud / h\u00e9bergeur : ouvrez aussi ces ports dans le groupe de s\u00e9curit\u00e9 / les ACL r\u00e9seau du fournisseur.'
        'sum_file' = 'R\u00e9capitulatif enregistr\u00e9 (root uniquement) : {0}'
        'sum_fallback' = 'Ce plan de contr\u00f4le n''a pas encore de commande ''bootstrap'' : ouvrez l''URL de la console et suivez la page de configuration.'
        'sum_node_hint' = 'Pour piloter ce n\u0153ud depuis la console : N\u0153uds > Ajouter un n\u0153ud, puis renseignez control_plane.url / enroll_token dans {0}.'
        'q_fwmodule' = 'Voulez-vous aussi que ToutWAF g\u00e8re le pare-feu de cette machine ?'
        'fwmod_n1' = 'Module optionnel, \u00e9teint sauf si vous r\u00e9pondez oui. Rien n''est appliqu\u00e9 pendant l''installation : vous relisez chaque changement dans la console.'
        's_bkclient' = 'Installation du client ToutWAF Backup (signature v\u00e9rifi\u00e9e)'
        'bkc_done' = 'Client ToutWAF Backup install\u00e9. \u00c9tape suivante : console, Sauvegardes > Serveurs de sauvegarde, pour associer un serveur.'
        'bkc_fail' = 'Le client ToutWAF Backup n\u2019a PAS \u00e9t\u00e9 install\u00e9 ({0}). L\u2019installation continue ; installez-le plus tard avec --with-backup-client.'
        'bkc_nokey' = 'Le client ToutWAF Backup n\u2019a PAS \u00e9t\u00e9 install\u00e9 : aucune cl\u00e9 publique de version. Donnez-la avec --backup-client-pubkey (ou TOUTWAF_BACKUP_PUBKEY, ou le fichier backup-release.pub du dossier de configuration) ; rien n\u2019est install\u00e9 sans signature v\u00e9rifi\u00e9e.'
        'bkc_badsig' = 'Le client ToutWAF Backup n\u2019a PAS \u00e9t\u00e9 install\u00e9 : la signature de la version n\u2019est PAS valide. Rien n\u2019a \u00e9t\u00e9 install\u00e9.'
        'tele_on' = 'T\u00e9l\u00e9m\u00e9trie : par d\u00e9faut, ToutWAF partage avec l''espace \u00e9diteur (app.toutwaf.com) les attaques qu''il a bloqu\u00e9es (adresse de l''attaquant, pays, type d''attaque, r\u00e8gle), des chiffres agr\u00e9g\u00e9s et les noms d''h\u00f4te des sites prot\u00e9g\u00e9s. Jamais le contenu des requ\u00eates ni les visiteurs l\u00e9gitimes. D\u00e9sactivable en un clic dans la console (Param\u00e8tres, Confidentialit\u00e9 et t\u00e9l\u00e9m\u00e9trie), ou installez avec --no-telemetry (ou TOUTWAF_TELEMETRY=0) pour une t\u00e9l\u00e9m\u00e9trie z\u00e9ro. D\u00e9tails : docs/confidentialite-telemetrie.md'
        'tele_off' = 'T\u00e9l\u00e9m\u00e9trie : la t\u00e9l\u00e9m\u00e9trie z\u00e9ro a \u00e9t\u00e9 demand\u00e9e (--no-telemetry / TOUTWAF_TELEMETRY=0). Rien ne sera envoy\u00e9 \u00e0 l''espace \u00e9diteur, rien n''en sera re\u00e7u, et la console d\u00e9marre avec l''interrupteur \u00ab T\u00e9l\u00e9m\u00e9trie z\u00e9ro \u00bb activ\u00e9. Vous pourrez changer cela plus tard dans la console (Param\u00e8tres, Confidentialit\u00e9 et t\u00e9l\u00e9m\u00e9trie).'
        'fwmod_n2' = 'Chaque changement passe par un essai avec compte \u00e0 rebours et revient en arri\u00e8re tout seul si vous ne le gardez pas ; un garde-fou anti-lockout refuse toute r\u00e8gle qui couperait SSH ou la console.'
        'fwmod_n3' = 'Ce n''est pas la question pr\u00e9c\u00e9dente, qui ouvre seulement les ports dont ToutWAF a besoin dans le pare-feu du syst\u00e8me (--no-firewall).'
        's_fwmod' = 'Activation du module pare-feu (aucune r\u00e8gle appliqu\u00e9e)'
        'fwmod_done' = 'Module pare-feu activ\u00e9. Rien n''a \u00e9t\u00e9 appliqu\u00e9 : ouvrez Pare-feu dans la console pour relire et essayer des r\u00e8gles.'
        'fwmod_fail' = 'Impossible d''activer le module pare-feu ({0}). L''installation continue ; activez-le plus tard dans Param\u00e8tres > Modules.'
        's_link' = 'Liaison du plan de donn\u00e9es \u00e0 la console'
        'dp_link_ok' = 'Plan de donn\u00e9es li\u00e9 automatiquement \u00e0 la console : rien \u00e0 configurer \u00e0 la main.'
        'dp_link_same' = 'Plan de donn\u00e9es d\u00e9j\u00e0 li\u00e9 \u00e0 la console ; sa configuration n''a pas \u00e9t\u00e9 modifi\u00e9e.'
        'dp_link_fixed' = 'Configuration du plan de donn\u00e9es r\u00e9par\u00e9e (blocs control_plane en double fusionn\u00e9s en un seul) ; l''ancien fichier est conserv\u00e9.'
        'dp_link_remote' = 'Le plan de donn\u00e9es de cette machine est configur\u00e9 pour une autre console ; il n''a pas \u00e9t\u00e9 modifi\u00e9.'
        'dp_link_fail' = 'Le plan de donn\u00e9es n''a pas pu \u00eatre li\u00e9 automatiquement \u00e0 la console : {0}'
        'dp_link_fail_hint' = 'Le plan de donn\u00e9es garde sa configuration autonome : les sites r\u00e9pondent HTTP 421 tant qu''il n''est pas li\u00e9. Corrigez la cause ci-dessus et relancez cet installateur : il lie le n\u0153ud tout seul.'
        'st_title' = '\u00c9tat'
        'st_healthy' = 'sain'
        'st_unhealthy' = 'NON sain'
        'st_active' = 'actif'
        'st_inactive' = 'inactif'
        'st_listening' = 'en \u00e9coute'
        'st_closed' = 'ferm\u00e9'
        'un_title' = 'D\u00e9sinstallation de ToutWAF'
        'un_kept' = 'Configuration conserv\u00e9e dans {0}, donn\u00e9es dans {1} (--purge pour supprimer).'
        'un_purged' = 'Configuration, donn\u00e9es et journaux supprim\u00e9s.'
        'p_console' = 'console web + API'
        'p_http' = 'HTTP (reverse proxy)'
        'p_https' = 'HTTPS (reverse proxy)'
        'p_dpapi' = 'API des plans de donn\u00e9es : UNIQUEMENT si des plans de donn\u00e9es sont sur D''AUTRES h\u00f4tes (limiter \u00e0 leurs IP)'
        'w_fw_manual' = 'Le port {0}/tcp n''a pas \u00e9t\u00e9 ouvert automatiquement : voir les commandes du r\u00e9capitulatif.'
        'need_cp' = 'Une URL de plan de contr\u00f4le est n\u00e9cessaire lorsqu''un jeton d''enr\u00f4lement est fourni.'
        'cp_title' = 'Compatibilit\u00e9 du syst\u00e8me'
        'cp_detected' = 'D\u00e9tect\u00e9 : {0}, arch {1}, glibc {2}, systemd {3}, noyau {4}'
        'cp_ok' = 'Compatible : {0} ({1})'
        'cp_tested' = 'test\u00e9'
        'cp_expected' = 'attendu'
        'cp_w_like' = '{0} n''est pas dans la table de compatibilit\u00e9 : trait\u00e9 comme la famille {1} (attendu). On continue.'
        'cp_w_newer' = '{0} {1} est plus r\u00e9cent que les versions list\u00e9es : pas encore valid\u00e9 (attendu). On continue.'
        'cp_w_unlisted' = '{0} {1} n''est pas list\u00e9 dans la table : trait\u00e9 comme attendu. On continue.'
        'cp_w_nover' = '{0} ne d\u00e9clare aucune version (distribution en continu ou testing) : trait\u00e9 comme attendu. On continue.'
        'cp_w_glibc' = 'La version de glibc n''a pas pu \u00eatre d\u00e9termin\u00e9e ; on continue.'
        'cp_w_skip' = '--skip-os-check : le contr\u00f4le de compatibilit\u00e9 est ignor\u00e9. Ce syst\u00e8me n''est PAS pris en charge : vous continuez \u00e0 vos risques.'
        'cp_w_stage' = 'Pr\u00e9paration (--destdir) : le verdict de compatibilit\u00e9 est informatif, rien n''est refus\u00e9.'
        'cp_refused' = 'Ce syst\u00e8me n''est pas compatible avec ToutWAF :'
        'cp_r_old' = '{0} {1} est plus ancien que la version minimale prise en charge ({2}).'
        'cp_r_eol' = '{0} {1} est en fin de vie, ou sa glibc / son systemd est trop ancien.'
        'cp_r_glibc' = 'glibc {0} trouv\u00e9e : {1} ou plus r\u00e9cente est requise.'
        'cp_r_musl' = 'musl libc trouv\u00e9e : glibc {0} ou plus r\u00e9cente est requise.'
        'cp_r_init' = '{0} {1} n''utilise pas systemd, requis par ToutWAF.'
        'cp_r_immutable' = '{0} {1} a un syst\u00e8me de fichiers racine immuable (non pris en charge).'
        'cp_r_layout' = '{0} {1} ne suit pas l''arborescence Linux standard (non pris en charge).'
        'cp_r_arch' = 'L''architecture {0} n''est pas prise en charge (prise en charge : {1}).'
        'cp_r_distro_arch' = '{0} {1} tourne sur une architecture sans build ToutWAF.'
        'cp_r_systemd' = 'systemd ne tourne pas comme syst\u00e8me d''init (/run/systemd/system est absent) : il est requis pour les services.'
        'cp_r_systemd_old' = 'systemd {0} trouv\u00e9 : {1} ou plus r\u00e9cent est requis.'
        'cp_r_kernel' = 'Noyau Linux {0} trouv\u00e9 : {1} ou plus r\u00e9cent est requis.'
        'cp_r_unknown' = 'La distribution ''{0}'' n''est pas reconnue et ne d\u00e9clare aucune famille connue (ID_LIKE=''{1}'').'
        'cp_r_noosr' = '/etc/os-release est absent : la distribution ne peut pas \u00eatre identifi\u00e9e.'
        'cp_nochange' = 'Rien n''a \u00e9t\u00e9 modifi\u00e9 sur ce syst\u00e8me.'
        'cp_list' = 'Syst\u00e8mes compatibles (amd64 et arm64, glibc {0} ou plus r\u00e9cente, systemd {1} ou plus r\u00e9cent) :'
        'cp_rolling' = 'en continu'
        'cp_any' = 'toute version'
        'cp_override' = 'Pour installer quand m\u00eame, \u00e0 vos risques : --skip-os-check. D\u00e9tails : docs/install/platforms.md'
        'cp_not_root' = 'Pas ex\u00e9cut\u00e9 en root : utilisez sudo pour installer (le contr\u00f4le lui-m\u00eame n''en a pas besoin).'
        'sum_compat' = 'Compatibilit\u00e9'
        'cp_prereq_arch' = 'Les bases de paquets ne sont pas synchronis\u00e9es. Lancez d''abord ''pacman -Syu'' (une mise \u00e0 jour partielle n''est pas prise en charge sur Arch), puis relancez l''installateur.'
        'cp_wdetected' = 'D\u00e9tect\u00e9 : {0} (build {1}), arch {2}'
        'cp_wlist' = 'Versions de Windows compatibles (amd64 et arm64 ; arm64 non test\u00e9 sur du mat\u00e9riel r\u00e9el) :'
        'cp_r_arm32' = 'L''ARM 32 bits (armv7) n''est pas pris en charge par ToutWAF. Installez un syst\u00e8me 64 bits (Raspberry Pi OS 64 bits, Ubuntu ou Debian arm64 ; Raspberry Pi 3, 4, 5 ou Zero 2 W), puis relancez l''installateur.'
        'cp_r_arm_userland32' = 'Le noyau est 64 bits mais le syst\u00e8me (userland) est en 32 bits. ToutWAF exige un syst\u00e8me 64 bits : r\u00e9installez avec Raspberry Pi OS 64 bits (Raspberry Pi Imager : Raspberry Pi OS (64-bit)) ou Ubuntu / Debian arm64.'
        'cp_w_pi' = 'Raspberry Pi d\u00e9tect\u00e9 : l''arm64 n''a \u00e9t\u00e9 \u00e9prouv\u00e9 que sous \u00e9mulation, pas sur du mat\u00e9riel r\u00e9el. Placez donn\u00e9es et journaux sur un SSD / disque USB plut\u00f4t que sur la carte SD, et \u00e9vitez l''installation tout-en-un sous 2 Go de RAM (voir docs/install/raspberry-pi.md).'
        'pf_title' = 'V\u00e9rification de ce dont cette machine a besoin'
        'pf_ok' = 'Rien ne g\u00eane : les ports dont ToutWAF a besoin sont libres.'
        'pf_refused' = 'ToutWAF ne peut pas \u00eatre install\u00e9 sur cette machine en l''\u00e9tat. Rien n''a \u00e9t\u00e9 modifi\u00e9.'
        'pf_ok_warn' = 'Rien n''emp\u00eache l''installation, mais lisez les points ci-dessus.'
        'pf_l_refuse' = 'refus\u00e9'
        'pf_l_warn' = 'attention'
        'pf_l_info' = '\u00e0 savoir'
        'pf_port_busy' = 'Le port {0} est d\u00e9j\u00e0 utilis\u00e9 par {1}.'
        'pf_prog_other' = 'un autre programme'
        'pf_prog_unknown' = 'un autre programme (son nom n''a pas pu \u00eatre lu)'
        'pf_act_web' = 'ToutWAF a besoin des ports {0} et {1} pour prot\u00e9ger vos sites. Arr\u00eatez ce programme ou d\u00e9placez-le sur d''autres ports (ToutPanel, install\u00e9 \u00e0 c\u00f4t\u00e9 de ToutWAF, place son serveur web sur 8080 et 8443), puis relancez l''installateur.'
        'pf_act_console' = 'La console de ToutWAF a besoin de ce port. Lib\u00e9rez-le, ou choisissez un autre port pour la console (l''installateur le demande dans son menu), puis relancez l''installateur.'
        'pf_act_agent' = 'ToutWAF utilise ce port pour les plans de donn\u00e9es et les agents qui s''y connectent. Lib\u00e9rez-le, puis relancez l''installateur.'
        'pf_act_admin' = 'Le plan de donn\u00e9es utilise ce port sur cette machine seulement, pour son propre contr\u00f4le de sant\u00e9. Lib\u00e9rez-le, puis relancez l''installateur.'
        'pf_nostart' = '(rien n''est d\u00e9marr\u00e9 maintenant, ce n''est donc que signal\u00e9)'
        'pf_boot' = '{0} est install\u00e9 et d\u00e9marre avec la machine, bien qu''il soit arr\u00eat\u00e9 en ce moment. Au prochain red\u00e9marrage il prendrait les ports {1} et {2} avant ToutWAF.'
        'pf_act_boot' = 'D\u00e9sactivez-le pour qu''il ne d\u00e9marre plus avec la machine, ou d\u00e9placez-le sur d''autres ports, avant le red\u00e9marrage de la machine.'
        'pf_fw_cause' = 'Un pare-feu ({0}) est actif et ne laisse pas passer les ports {1} et {2}, et l''installateur a re\u00e7u l''ordre de ne pas le modifier.'
        'pf_fw_action' = 'Ouvrez ces ports dans le pare-feu, ou laissez l''installateur le faire (sans l''option --no-firewall). Sinon, vos sites ne seront pas joignables de l''ext\u00e9rieur.'
        'pf_fwx_cause' = 'Le pare-feu de cette machine ({0}) refuse les connexions entrantes par d\u00e9faut et n''a aucune r\u00e8gle pour les ports {1} et {2}.'
        'pf_fwx_action' = 'ToutWAF ne modifie jamais lui-m\u00eame les r\u00e8gles de ce type de pare-feu : ouvrez ces ports dans sa configuration, puis v\u00e9rifiez vos sites.'
        'pf_cp_cause' = 'Le plan de contr\u00f4le {0} est injoignable depuis cette machine.'
        'pf_cp_action' = 'V\u00e9rifiez l''adresse, que le plan de contr\u00f4le fonctionne et que son pare-feu laisse cette machine l''atteindre (port 9444 par d\u00e9faut), puis relancez l''installateur.'
        'pf_router_cause' = 'Cette machine a une adresse priv\u00e9e ({0}) : elle est probablement derri\u00e8re un routeur ou une box.'
        'pf_router_action' = 'Une fois install\u00e9, ToutWAF indique les ports \u00e0 rediriger vers cette machine et fournit les fichiers pour les routeurs usuels. Il n''y a rien \u00e0 pr\u00e9parer maintenant.'
        'pf_skipped' = 'La v\u00e9rification de l''environnement a \u00e9t\u00e9 saut\u00e9e \u00e0 votre demande : ce qui g\u00eane fera \u00e9chouer l''installation ou le d\u00e9marrage plus tard.'
        's_sysupdate' = 'Mise \u00e0 jour des paquets syst\u00e8me (cela peut prendre plusieurs minutes)'
        'su_skipped' = 'Les paquets syst\u00e8me ne sont pas mis \u00e0 jour au pr\u00e9alable (TOUTWAF_SKIP_SYSUPDATE).'
        'su_recent' = 'Les paquets syst\u00e8me ont \u00e9t\u00e9 mis \u00e0 jour il y a moins de 6 heures : pas de nouvelle mise \u00e0 jour.'
        'su_dry' = 'les paquets syst\u00e8me seraient d''abord mis \u00e0 jour (\u00e0 \u00e9viter avec TOUTWAF_SKIP_SYSUPDATE=1)'
        'su_nopm' = 'Aucun gestionnaire de paquets pris en charge pour mettre le syst\u00e8me \u00e0 jour : \u00e9tape ignor\u00e9e, l''installation continue.'
        'su_failed' = 'La mise \u00e0 jour des paquets syst\u00e8me a \u00e9chou\u00e9 (code {0}) ; l''installation continue sans elle. D\u00e9tails : {1}. Correction : lancez la mise \u00e0 jour vous-m\u00eame et lisez son erreur (d\u00e9p\u00f4t cass\u00e9 ? un autre gestionnaire de paquets en cours ?), ou relancez cette commande avec TOUTWAF_SKIP_SYSUPDATE=1.'
        'su_reboot' = 'Un red\u00e9marrage de ce serveur est n\u00e9cessaire pour terminer la mise \u00e0 jour du syst\u00e8me (nouveau noyau ou nouvelles biblioth\u00e8ques). ToutWAF ne le red\u00e9marre jamais \u00e0 votre place : faites-le d\u00e8s que possible.'
        'q_sysupdate' = 'Mettre d''abord \u00e0 jour les paquets syst\u00e8me (recommand\u00e9) ?'
        'pr_disk_full' = 'Seulement {0} Mo sont libres sur {1} (il en faut au moins {2} Mo) : l''installation ne pourrait pas se terminer.'
        'pr_disk_full_a' = 'Lib\u00e9rez de la place (cache des paquets : apt-get clean ou dnf clean all ; anciens journaux : journalctl --vacuum-size=100M), puis relancez cette commande. Pour continuer malgr\u00e9 tout : TOUTWAF_SKIP_PREREQ=1.'
        'pr_disk_full_w_a' = 'Lib\u00e9rez de la place (Nettoyage de disque, vidage de la corbeille), puis relancez cette commande. Pour continuer malgr\u00e9 tout : $env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = 'Seulement {0} Mo sont libres sur {1} (environ {2} Mo sont confortables).'
        'pr_disk_low_a' = 'Lib\u00e9rez de la place ou ajoutez du disque ; l''installation peut continuer.'
        'pr_dns' = 'Cette machine ne parvient pas \u00e0 r\u00e9soudre le nom {0} (DNS).'
        'pr_dns_a' = 'V\u00e9rifiez les serveurs DNS (cat /etc/resolv.conf, resolvectl status), ajoutez-en un qui fonctionne, par exemple nameserver 9.9.9.9, puis relancez cette commande.'
        'pr_dns_w_a' = 'V\u00e9rifiez les serveurs DNS avec ''ipconfig /all'', indiquez-en un qui fonctionne (par exemple 9.9.9.9) dans les param\u00e8tres de la carte r\u00e9seau, puis relancez cette commande.'
        'pr_clock' = 'L''horloge de cette machine est d\u00e9cal\u00e9e de {0} secondes par rapport \u00e0 l''heure d''Internet : les certificats TLS et les signatures \u00e9chouent quand l''horloge est fausse.'
        'pr_clock_a' = 'Synchronisez-la : timedatectl set-ntp true (ou chronyc makestep), v\u00e9rifiez avec timedatectl, puis relancez cette commande.'
        'pr_clock_w_a' = 'Synchronisez-la : w32tm /resync (ou Param\u00e8tres > Heure et langue > Synchroniser maintenant), puis relancez cette commande.'
        'pr_ok' = 'L''espace disque, le DNS et l''horloge sont en ordre.'
        'cloud_https' = '--cloud-url doit \u00eatre une adresse https:// (le n\u0153ud ne parle jamais au cloud en clair).'
        'cloud_dp_only' = '--cloud-url installe un n\u0153ud de protection : utilisez-le avec --component dp (le d\u00e9faut en mode cloud).'
        'cloud_need_token' = 'Un jeton d''enr\u00f4lement est n\u00e9cessaire pour relier ce n\u0153ud \u00e0 votre compte (--enroll-token ; console : N\u0153uds > Ajouter mon premier n\u0153ud).'
        'cloud_ca_local' = '--cloud-ca doit \u00eatre un fichier local.'
        'cloud_nolink' = 'Cette version ne contient pas le lien ToutWAF Cloud (toutwaf-cloudlink) : mettez l''installateur \u00e0 jour ou utilisez une version plus r\u00e9cente.'
        'cloud_enrol_failed' = 'Le n\u0153ud n''a pas pu \u00eatre enr\u00f4l\u00e9 aupr\u00e8s de votre compte (voir les lignes ci-dessus). Le jeton est peut-\u00eatre utilis\u00e9 ou p\u00e9rim\u00e9 : cr\u00e9ez-en un nouveau dans la console.'
        'pf_cloud_action' = 'Autorisez cette machine \u00e0 joindre l''adresse de votre ToutWAF Cloud sur le port 443 (sortant uniquement), ou d\u00e9finissez HTTPS_PROXY si un proxy est n\u00e9cessaire. Rien n''est \u00e0 ouvrir en entr\u00e9e.'
        's_db' = 'Pr\u00e9paration de la base de donn\u00e9es'
        'db_choose' = 'Quelle base de donn\u00e9es ToutWAF doit-il utiliser ?'
        'db_opt_pg' = 'PostgreSQL (recommand\u00e9)'
        'db_opt_pg_local' = 'Installer PostgreSQL sur cette machine (cr\u00e9\u00e9 et configur\u00e9 pour vous)'
        'db_opt_pg_remote' = 'Utiliser un serveur PostgreSQL existant (test\u00e9, puis pr\u00e9par\u00e9 si vous l''autorisez)'
        'db_opt_sqlite' = 'SQLite (petite installation, un seul serveur)'
        'db_sqlite_note' = 'SQLite est un fichier sur cette machine : adapt\u00e9 \u00e0 une petite installation sur un seul serveur. Il ne peut pas \u00eatre partag\u00e9 entre plusieurs plans de contr\u00f4le et n''a pas de r\u00e9plication. Vous pourrez passer \u00e0 PostgreSQL plus tard avec : toutwaf-cp db migrate.'
        'db_q_host' = 'H\u00f4te PostgreSQL'
        'db_q_port' = 'Port'
        'db_q_name' = 'Nom de la base'
        'db_q_user' = 'Utilisateur de la base'
        'db_q_pw' = 'Mot de passe de cet utilisateur (vide si un compte administrateur le cr\u00e9e)'
        'db_q_tls' = 'Mode TLS (disable, prefer, require, verify-ca, verify-full)'
        'db_q_ca' = 'Fichier du certificat de l''autorit\u00e9 du serveur (pour verify-ca / verify-full)'
        'db_q_admin' = 'Compte administrateur qui cr\u00e9e l''utilisateur et la base (vide = ils existent d\u00e9j\u00e0)'
        'db_q_adminpw' = 'Mot de passe du compte administrateur (utilis\u00e9 une fois, jamais stock\u00e9)'
        'db_hint' = 'Base de donn\u00e9es : SQLite (par d\u00e9faut). Pour une installation serveur ou plusieurs plans de contr\u00f4le, utilisez --db postgres (--db-install-local l''installe pour vous).'
        'db_no_pkg' = 'PostgreSQL ne peut pas \u00eatre install\u00e9 automatiquement sur ce syst\u00e8me : installez vous-m\u00eame le paquet serveur, puis relancez l''installateur avec --db postgres.'
        'db_install_failed' = 'L''installation du paquet PostgreSQL a \u00e9chou\u00e9. Le journal dit pourquoi (/var/log/toutwaf-install.log).'
        'db_init_failed' = 'Le cluster PostgreSQL n''a pas pu \u00eatre initialis\u00e9. Le journal dit pourquoi.'
        'db_start_failed' = 'PostgreSQL ne d\u00e9marre pas. V\u00e9rifiez : systemctl status postgresql, et le journal.'
        'db_too_old' = 'La version de PostgreSQL install\u00e9e ici ({0}) est trop ancienne : la version 13 ou plus r\u00e9cente est requise.'
        'db_exists' = 'Un utilisateur "{0}" ou une base "{1}" existe d\u00e9j\u00e0 et n''a pas \u00e9t\u00e9 cr\u00e9\u00e9 par cet installateur : rien n''a \u00e9t\u00e9 modifi\u00e9. Choisissez d''autres noms (--db-name, --db-user) ou donnez la connexion existante (--db-dsn-file).'
        'db_create_failed' = 'L''utilisateur ou la base n''a pas pu \u00eatre cr\u00e9\u00e9. Ce qui avait \u00e9t\u00e9 cr\u00e9\u00e9 a \u00e9t\u00e9 supprim\u00e9.'
        'db_rights' = 'Le compte n''a pas les droits n\u00e9cessaires. Les instructions ci-dessus sont le minimum qu''un administrateur du serveur doit ex\u00e9cuter ; relancez ensuite l''installateur.'
        'db_need_conn' = 'Aucune connexion au serveur PostgreSQL n''a \u00e9t\u00e9 donn\u00e9e : utilisez --db-dsn-file, ou --db-host avec --db-password-file, ou --db-install-local.'
        'db_schema_failed' = 'Les tables n''ont pas pu \u00eatre cr\u00e9\u00e9es dans la base. Le journal dit pourquoi.'
        'db_no_pgdump' = 'pg_dump est absent : la sauvegarde quotidienne de la base signalera une erreur tant que le paquet client PostgreSQL n''est pas install\u00e9.'
        'db_sum_engine' = 'Base de donn\u00e9es : {0}'
        'db_sum_local' = 'PostgreSQL tourne sur cette machine (boucle locale uniquement) ; base {0}, utilisateur {1} (sans droits d''administration)'
        'db_sum_remote' = 'Serveur PostgreSQL existant ; base {0}, utilisateur {1}'
        'db_sum_schema' = 'Sch\u00e9ma : {0}'
        'db_sum_secret' = 'La connexion (avec son mot de passe) est dans {0}, lisible par le seul service ToutWAF'
        'db_sum_backup' = 'Un pg_dump v\u00e9rifi\u00e9 s''ex\u00e9cute chaque nuit (7 conserv\u00e9s) ; \u00e9tat dans la console, Sant\u00e9'
        'db_sum_nobackup' = 'Pas de sauvegarde automatique de la base : planifiez pg_dump ou utilisez la sauvegarde de votre h\u00e9bergeur de base'
        'db_sum_sqlite' = 'Base de donn\u00e9es : SQLite, un fichier sur cette machine (petite installation). Passer \u00e0 PostgreSQL plus tard : toutwaf-cp db migrate'
        's_extras' = 'Extras : agent Windows et programmes de l''antivirus'
        's_extras_ok' = 'Extras install\u00e9s : {0} programmes dans {1}'
        's_extras_sha' = 'Extras v\u00e9rifi\u00e9s : {0} fichier(s), {1} Mio (SHA-256 et signature)'
        's_extras_unchecked' = 'Extras pris tels quels, sans SHA256SUMS pour les v\u00e9rifier : {0}'
        'w_extras_dl' = 'Les extras n''ont pas pu \u00eatre t\u00e9l\u00e9charg\u00e9s ({0}). ToutWAF fonctionne sans eux, mais cette console ne proposera ni Windows ni l''antivirus tant qu''ils ne sont pas install\u00e9s.'
        'w_extras_sum' = 'Les extras {0} ne correspondent pas \u00e0 leur SHA-256 du SHA256SUMS sign\u00e9 : ils n''ont PAS \u00e9t\u00e9 install\u00e9s.'
        'w_extras_bad' = 'Le fichier d''extras {0} n''est pas une archive d''extras valide : il n''a PAS \u00e9t\u00e9 install\u00e9.'
        'w_extras_ver' = 'Les extras sont de la version {0}, cette installation est en {1} : ils n''ont PAS \u00e9t\u00e9 install\u00e9s.'
        'w_extras_inc' = 'La version liste {0} partie(s) des extras mais annonce {1} : la publication est ab\u00eem\u00e9e, les extras n''ont PAS \u00e9t\u00e9 install\u00e9s.'
        'w_extras_nofile' = 'Le fichier d''extras {0} n''existe pas.'
        'w_extras_none' = 'Cette version ne contient pas d''extras : cette console ne proposera ni Windows ni l''antivirus.'
        'w_extras_todo' = 'Extras non install\u00e9s. Quand le r\u00e9seau le permet, lancez en root : {0}'
        'extras_needs_cp' = 'Les extras appartiennent au plan de contr\u00f4le : il n''est pas install\u00e9 sur cette machine.'
        'extras_other_release' = 'La version publi\u00e9e ({0}) n''est pas celle qui est install\u00e9e ({1}) : les extras viennent avec elle. Lancez --update.'
        'st_extras_ok' = 'Extras : install\u00e9s (agent Windows, programmes de l''antivirus)'
        'st_extras_none' = 'Extras absents : Windows et l''antivirus ne sont pas propos\u00e9s. Lancez en root : {0}'
    }
    'es' = @{
        'tagline' = 'Protecci\u00f3n de aplicaciones web y API'
        'menu_title' = '\u00bfQu\u00e9 desea hacer?'
        'opt_install' = 'Instalar (plano de control + plano de datos + consola)'
        'opt_install_d' = 'Todo en esta m\u00e1quina: consola web, almac\u00e9n de pol\u00edticas y proxy inverso / WAF.'
        'opt_cp' = 'Instalar solo el plano de control'
        'opt_cp_d' = 'Consola web, API y almac\u00e9n de pol\u00edticas. Los planos de datos (nodos) se unen despu\u00e9s.'
        'opt_dp' = 'Instalar solo un plano de datos'
        'opt_dp_d' = 'Nodo de proxy inverso / WAF que se une a un plano de control existente (pide su URL y un token de alta).'
        'opt_update' = 'Actualizar'
        'opt_update_d' = 'Descarga una versi\u00f3n m\u00e1s reciente, la verifica (SHA-256 / sigstore), hace copia, conserva configuraci\u00f3n y datos y revierte si falla.'
        'opt_uninstall' = 'Desinstalar'
        'opt_uninstall_d' = 'Elimina ToutWAF; usted elige conservar o borrar configuraci\u00f3n, datos y registros.'
        'opt_status' = 'Estado y comprobaci\u00f3n de salud'
        'opt_status_d' = 'Versiones instaladas, servicios, puertos en escucha y endpoints de salud.'
        'opt_links' = 'Mostrar de nuevo los enlaces del panel'
        'opt_links_d' = 'URL del panel, enlace de configuraci\u00f3n de un solo uso y puertos a abrir en el cortafuegos.'
        'opt_quit' = 'Salir'
        'choice' = 'Su elecci\u00f3n'
        'invalid_choice' = 'Elecci\u00f3n no v\u00e1lida.'
        'state_installed' = 'Instalado: {0}'
        'state_none' = 'ToutWAF no est\u00e1 instalado en esta m\u00e1quina.'
        'cfg_title' = 'Opciones de instalaci\u00f3n (Intro = valor por defecto)'
        'q_cp_url' = 'URL del plano de control (p. ej. https://cp.example.com:9444)'
        'q_token' = 'Token de alta (consola: Nodos > Agregar nodo)'
        'q_cp_ca' = 'Archivo PEM de la CA / certificado del plano de control (vac\u00edo = almac\u00e9n del sistema)'
        'q_cp_port' = 'Puerto de la consola'
        'q_http_port' = 'Puerto HTTP'
        'q_https_port' = 'Puerto HTTPS'
        'q_public_host' = 'Nombre de host o IP p\u00fablica (vac\u00edo = detecci\u00f3n autom\u00e1tica)'
        'q_firewall' = '\u00bfAbrir el cortafuegos autom\u00e1ticamente (firewalld / ufw)?'
        'q_boot' = '\u00bfIniciar los servicios al arrancar?'
        'q_channel' = 'Canal de versiones (stable / dev)'
        'q_bindir' = 'Directorio de instalaci\u00f3n'
        'q_confirm' = '\u00bfContinuar con la instalaci\u00f3n?'
        'q_purge' = '\u00bfBorrar tambi\u00e9n configuraci\u00f3n, datos y registros? (No = conservarlos)'
        'q_confirm_un' = '\u00bfDesinstalar ToutWAF de verdad?'
        'aborted' = 'Cancelado.'
        'root_required' = 'Ejecute como root (sudo bash install.sh).'
        's_prereq' = 'Instalando requisitos previos'
        's_fetch' = 'Descargando ToutWAF {0} ({1})'
        's_sha' = 'SHA-256 verificado'
        's_sig' = 'Firma cosign verificada'
        'w_nocosign' = 'cosign no instalado: firma sin verificar (solo suma de control)'
        's_user' = 'Creando la cuenta de servicio y los directorios'
        's_bin' = 'Instalando binarios'
        's_cfg' = 'Escribiendo la configuraci\u00f3n (se conservan los archivos existentes)'
        's_units' = 'Instalando unidades systemd y ajustes del sistema'
        's_selinux' = 'Configurando SELinux'
        'q_console_from' = 'Permitir solo esta red hacia la consola (CIDR, p. ej. 203.0.113.0/24; vac\u00edo = cualquiera)'
        'q_console_from_bad' = 'No es una direcci\u00f3n ni un CIDR (0.0.0.0/0 equivale a vac\u00edo): el puerto de la consola queda abierto a todos.'
        'fw_console_note' = 'La consola (puerto {0}) contiene el acceso de administraci\u00f3n: abrirla a todo Internet es c\u00f3modo pero expuesto.'
        'fw_console_open' = 'El puerto {0} de la consola est\u00e1 abierto a todos: restr\u00ednjalo con --console-from CIDR o en la consola (Ajustes > Cortafuegos)'
        'fw_console_from' = 'El puerto {0} de la consola solo est\u00e1 abierto a {1}'
        'fw_none' = 'No hay cortafuegos activo (firewalld / ufw / nftables / iptables): nada filtra el tr\u00e1fico, no hay puertos que abrir'
        'fw_manual' = 'El cortafuegos {0} no lo modifica el instalador: ejecute usted estos comandos'
        'fw_failed' = 'No se pudo configurar el cortafuegos: {0}'
        'home_fresh' = 'Instalaci\u00f3n nueva: todo va bajo {0} (bin, conf, data, logs)'
        'home_legacy' = 'Instalaci\u00f3n existente detectada: se mantienen sus rutas (bin {0}, conf {1}, data {2}). No se mueve nada; use --home DIR para la nueva disposici\u00f3n.'
        'home_explicit_legacy' = 'Se indic\u00f3 --home {0} mientras existe una instalaci\u00f3n en {1}: sus datos NO se mueven'
        'home_bad' = '--home debe ser una ruta absoluta (letras, d\u00edgitos, . _ - + /), no / ni bajo /proc /sys /dev: {0}'
        'home_noexec' = '{0} est\u00e1 en un montaje noexec: los binarios no podr\u00edan ejecutarse all\u00ed, elija otro --home'
        's_fw' = 'Configurando el cortafuegos'
        's_boot' = 'Preparando el panel (cuenta de administrador, ruta segura)'
        's_start' = 'Iniciando los servicios'
        's_health' = 'Esperando a que los servicios est\u00e9n sanos'
        's_backup' = 'Copia de seguridad de configuraci\u00f3n y datos'
        'w_rollback' = 'La nueva versi\u00f3n no est\u00e1 sana: volviendo a la anterior'
        'up_to_date' = 'Ya est\u00e1 actualizado ({0})'
        'not_installed' = 'ToutWAF no est\u00e1 instalado: nada que actualizar.'
        'st_channel' = 'Canal: {0}'
        'st_latest' = '\u00daltima versi\u00f3n disponible: {0}'
        'st_newer' = 'actualizaci\u00f3n disponible: ejecute con --update'
        'e_yanked' = 'La versi\u00f3n {0} fue retirada (yanked) y no debe instalarse. Ejecute --update para la versi\u00f3n actual, o --force para ignorarlo.'
        'e_nover' = 'Todav\u00eda no hay ninguna versi\u00f3n publicada en el canal {0}, as\u00ed que no hay nada que instalar. ToutWAF no se ha instalado ni modificado. Para instalar desde el canal {1}, vuelva a ejecutar el instalador con -Channel {2}.'
        'e_installer_old' = 'Este instalador es demasiado antiguo para esta versi\u00f3n (requiere la versi\u00f3n {0}): desc\u00e1rguelo de nuevo desde la URL del canal.'
        'up_rebuilt' = 'Misma versi\u00f3n, nueva compilaci\u00f3n: instalada {0}, disponible {1}. Actualizando.'
        'st_newbuild' = 'misma versi\u00f3n, nueva compilaci\u00f3n disponible: ejecute de nuevo con {0}'
        'st_nochannel' = '\u00daltima versi\u00f3n disponible: todav\u00eda no hay nada publicado en este canal'
        'w_mirror' = 'El espejo p\u00fablico ha servido archivos que no concuerdan entre s\u00ed ({0}): probablemente a\u00fan se est\u00e1 actualizando tras una publicaci\u00f3n. Se lee el canal de nuevo, una sola vez.'
        'e_mismatch' = 'suma de comprobaci\u00f3n incorrecta para {0} ({1}): el archivo descargado no coincide con la suma publicada, por lo que no se ha instalado ni modificado nada. Justo despu\u00e9s de una publicaci\u00f3n, el espejo p\u00fablico puede servir los archivos anteriores durante unos minutos: espere cinco minutos y vuelva a ejecutar el instalador. Si se repite, no instale: la publicaci\u00f3n est\u00e1 da\u00f1ada.'
        'e_downgrade' = 'La \u00faltima versi\u00f3n {0} del canal {1} es anterior a la instalada {2}: use --force para degradar.'
        's_sigok' = 'firma de la versi\u00f3n verificada, clave {0}'
        'w_sigold' = 'la versi\u00f3n {0} se public\u00f3 sin firma (las anteriores a 0.2.0-dev.7 no est\u00e1n firmadas): solo se verific\u00f3 el SHA-256, no se pudo comprobar la firma'
        'w_sigskip' = 'firma de la versi\u00f3n NO verificada: no se encontr\u00f3 openssl.exe en el PATH (Windows no incluye verificaci\u00f3n Ed25519), solo se comprob\u00f3 el SHA-256. Instale OpenSSL 3 y vuelva a ejecutar para verificar con la clave {0}'
        'done' = 'Hecho.'
        'failed' = 'Error'
        'log_hint' = 'Registro completo: {0}'
        'dry_done' = 'Simulaci\u00f3n: no se ha cambiado nada.'
        'sum_title' = 'Resumen de la instalaci\u00f3n'
        'sum_panel' = 'Enlaces del panel'
        'sum_tls_note' = 'Solo HTTPS. El certificado es autofirmado hasta que instale el suyo: el navegador mostrar\u00e1 una advertencia.'
        'sum_local' = 'Direcciones locales'
        'sum_public' = 'Direcci\u00f3n p\u00fablica'
        'sum_public_unknown' = 'No se pudo detectar la IP p\u00fablica (sin conexi\u00f3n o bloqueada). Use la IP p\u00fablica o el nombre DNS de su servidor en lugar de las direcciones locales, o vuelva a ejecutar con --public-host.'
        'sum_admin' = 'Cuenta de administrador'
        'sum_user' = 'Usuario'
        'sum_password' = 'Contrase\u00f1a'
        'sum_pw_once' = 'se muestra UNA sola vez - c\u00e1mbiela en Ajustes > Acceso / Cuenta'
        'sum_pw_unchanged' = 'sin cambios (nunca se regenera). Restabl\u00e9zcala con: toutwaf-cp admin reset-password --user {0}'
        'sum_setup' = 'Enlace de configuraci\u00f3n de un solo uso'
        'sum_setup_note' = '\u00c1bralo para configurar el enlace del panel, la cuenta y la contrase\u00f1a en el asistente web.'
        'p_dpapi_warn' = 'El puerto 9444 (API del data plane) NO est\u00e1 abierto: perm\u00edtalo solo desde sus nodos data plane'
        'p_dpapi_only' = '9444/tcp solo desde sus data planes, p. ej.:'
        'sum_setup_none' = 'Esta vez no hay enlace de configuraci\u00f3n (ya emitido, o la cuenta ya exist\u00eda). Cree uno con: toutwaf-cp setup-link --regenerate'
        'sum_ports' = 'Puertos a abrir en el cortafuegos'
        'sum_cmds' = 'Comandos'
        'sum_cloud' = 'Nube / hosting: abra tambi\u00e9n estos puertos en el grupo de seguridad / ACL de red del proveedor.'
        'sum_file' = 'Resumen guardado (solo root): {0}'
        'sum_fallback' = 'Este plano de control a\u00fan no tiene el comando ''bootstrap'': abra la URL de la consola y siga la p\u00e1gina de configuraci\u00f3n.'
        'sum_node_hint' = 'Para gestionar este nodo desde la consola: Nodos > Agregar nodo y configure control_plane.url / enroll_token en {0}.'
        'q_fwmodule' = '\u00bfQuiere que ToutWAF gestione tambi\u00e9n el cortafuegos de esta m\u00e1quina?'
        'fwmod_n1' = 'M\u00f3dulo opcional, apagado salvo que diga s\u00ed. No se aplica nada durante la instalaci\u00f3n: revisa cada cambio en la consola.'
        's_bkclient' = 'Instalando el cliente ToutWAF Backup (firma verificada)'
        'bkc_done' = 'Cliente ToutWAF Backup instalado. Siguiente: consola, Copias > Servidores de copia, para vincular un servidor.'
        'bkc_fail' = 'El cliente ToutWAF Backup NO se instal\u00f3 ({0}). La instalaci\u00f3n contin\u00faa; inst\u00e1lelo despu\u00e9s con --with-backup-client.'
        'bkc_nokey' = 'El cliente ToutWAF Backup NO se instal\u00f3: falta la clave p\u00fablica de la versi\u00f3n. Ind\u00edquela con --backup-client-pubkey (o TOUTWAF_BACKUP_PUBKEY, o el archivo backup-release.pub de la carpeta de configuraci\u00f3n); nada se instala sin firma verificada.'
        'bkc_badsig' = 'El cliente ToutWAF Backup NO se instal\u00f3: la firma de la versi\u00f3n NO es v\u00e1lida. No se instal\u00f3 nada.'
        'tele_on' = 'Telemetr\u00eda: por defecto ToutWAF comparte con el espacio del editor (app.toutwaf.com) los ataques que bloque\u00f3 (direcci\u00f3n del atacante, pa\u00eds, tipo de ataque, regla), cifras agregadas y los nombres de host de los sitios protegidos. Nunca el contenido de las solicitudes ni a los visitantes leg\u00edtimos. Se desactiva con un clic en la consola (Ajustes, Privacidad y telemetr\u00eda), o instale con --no-telemetry (o TOUTWAF_TELEMETRY=0) para telemetr\u00eda cero. Detalles: docs/confidentialite-telemetrie.md'
        'tele_off' = 'Telemetr\u00eda: se pidi\u00f3 telemetr\u00eda cero (--no-telemetry / TOUTWAF_TELEMETRY=0). No se enviar\u00e1 nada al espacio del editor, no se recibir\u00e1 nada de \u00e9l y la consola arrancar\u00e1 con el interruptor \u00abTelemetr\u00eda cero\u00bb activado. Podr\u00e1 cambiarlo m\u00e1s tarde en la consola (Ajustes, Privacidad y telemetr\u00eda).'
        'fwmod_n2' = 'Cada cambio se prueba con cuenta atr\u00e1s y se revierte solo si no lo conserva; una protecci\u00f3n anti-bloqueo rechaza toda regla que cortar\u00eda SSH o la consola.'
        'fwmod_n3' = 'No es la pregunta anterior, que solo abre los puertos que ToutWAF necesita en el cortafuegos del sistema (--no-firewall).'
        's_fwmod' = 'Activando el m\u00f3dulo de cortafuegos (ninguna regla aplicada)'
        'fwmod_done' = 'M\u00f3dulo de cortafuegos activado. No se aplic\u00f3 nada: abra Cortafuegos en la consola para revisar y probar reglas.'
        'fwmod_fail' = 'No se pudo activar el m\u00f3dulo de cortafuegos ({0}). La instalaci\u00f3n contin\u00faa; act\u00edvelo despu\u00e9s en Ajustes > M\u00f3dulos.'
        's_link' = 'Vinculando el plano de datos a la consola'
        'dp_link_ok' = 'Plano de datos vinculado autom\u00e1ticamente a la consola: nada que configurar a mano.'
        'dp_link_same' = 'El plano de datos ya est\u00e1 vinculado a la consola; su configuraci\u00f3n no se modific\u00f3.'
        'dp_link_fixed' = 'Configuraci\u00f3n del plano de datos reparada (bloques control_plane duplicados fusionados en uno); se conserv\u00f3 el archivo anterior.'
        'dp_link_remote' = 'El plano de datos de esta m\u00e1quina est\u00e1 configurado para otra consola; no se modific\u00f3.'
        'dp_link_fail' = 'No se pudo vincular autom\u00e1ticamente el plano de datos a la consola: {0}'
        'dp_link_fail_hint' = 'El plano de datos conserva su configuraci\u00f3n aut\u00f3noma, por lo que los sitios responden HTTP 421 hasta que se vincule. Corrija la causa indicada y vuelva a ejecutar este instalador: vincula el nodo por s\u00ed solo.'
        'st_title' = 'Estado'
        'st_healthy' = 'sano'
        'st_unhealthy' = 'NO sano'
        'st_active' = 'activo'
        'st_inactive' = 'inactivo'
        'st_listening' = 'escuchando'
        'st_closed' = 'no escucha'
        'un_title' = 'Desinstalando ToutWAF'
        'un_kept' = 'Configuraci\u00f3n conservada en {0}, datos en {1} (use --purge para borrar).'
        'un_purged' = 'Configuraci\u00f3n, datos y registros eliminados.'
        'p_console' = 'consola web + API'
        'p_http' = 'HTTP (proxy inverso)'
        'p_https' = 'HTTPS (proxy inverso)'
        'p_dpapi' = 'API de planos de datos: SOLO si hay planos de datos en OTROS hosts (limitar a sus IP)'
        'w_fw_manual' = 'El puerto {0}/tcp no se abri\u00f3 autom\u00e1ticamente: vea los comandos del resumen.'
        'need_cp' = 'Se necesita la URL de un plano de control cuando se indica un token de alta.'
        'cp_title' = 'Compatibilidad del sistema'
        'cp_detected' = 'Detectado: {0}, arq. {1}, glibc {2}, systemd {3}, kernel {4}'
        'cp_ok' = 'Compatible: {0} ({1})'
        'cp_tested' = 'probado'
        'cp_expected' = 'esperado'
        'cp_w_like' = '{0} no figura en la tabla de compatibilidad: se trata como la familia {1} (esperado). Se contin\u00faa.'
        'cp_w_newer' = '{0} {1} es m\u00e1s reciente que las versiones listadas: a\u00fan no validado (esperado). Se contin\u00faa.'
        'cp_w_unlisted' = '{0} {1} no figura en la tabla: se trata como esperado. Se contin\u00faa.'
        'cp_w_nover' = '{0} no declara versi\u00f3n (rolling o testing): se trata como esperado. Se contin\u00faa.'
        'cp_w_glibc' = 'No se pudo determinar la versi\u00f3n de glibc; se contin\u00faa.'
        'cp_w_skip' = '--skip-os-check: se omite la comprobaci\u00f3n de compatibilidad. Este sistema NO es compatible: contin\u00faa bajo su responsabilidad.'
        'cp_w_stage' = 'Preparaci\u00f3n (--destdir): el veredicto de compatibilidad es informativo, no se rechaza nada.'
        'cp_refused' = 'Este sistema no es compatible con ToutWAF:'
        'cp_r_old' = '{0} {1} es anterior a la versi\u00f3n m\u00ednima compatible ({2}).'
        'cp_r_eol' = '{0} {1} ha llegado al fin de su vida \u00fatil, o su glibc / systemd es demasiado antiguo.'
        'cp_r_glibc' = 'glibc {0} encontrada: se requiere {1} o posterior.'
        'cp_r_musl' = 'musl libc encontrada: se requiere glibc {0} o posterior.'
        'cp_r_init' = '{0} {1} no usa systemd, que ToutWAF requiere.'
        'cp_r_immutable' = '{0} {1} tiene un sistema de archivos ra\u00edz inmutable (no compatible).'
        'cp_r_layout' = '{0} {1} no sigue la estructura est\u00e1ndar de Linux (no compatible).'
        'cp_r_arch' = 'La arquitectura {0} no es compatible (compatible: {1}).'
        'cp_r_distro_arch' = '{0} {1} funciona en una arquitectura sin compilaci\u00f3n de ToutWAF.'
        'cp_r_systemd' = 'systemd no se ejecuta como sistema init (falta /run/systemd/system): es necesario para los servicios.'
        'cp_r_systemd_old' = 'systemd {0} encontrado: se requiere {1} o posterior.'
        'cp_r_kernel' = 'Kernel Linux {0} encontrado: se requiere {1} o posterior.'
        'cp_r_unknown' = 'La distribuci\u00f3n ''{0}'' no se reconoce y no declara ninguna familia conocida (ID_LIKE=''{1}'').'
        'cp_r_noosr' = 'Falta /etc/os-release: no se puede identificar la distribuci\u00f3n.'
        'cp_nochange' = 'No se ha modificado nada en este sistema.'
        'cp_list' = 'Sistemas compatibles (amd64 y arm64, glibc {0} o posterior, systemd {1} o posterior):'
        'cp_rolling' = 'rolling'
        'cp_any' = 'cualquier versi\u00f3n'
        'cp_override' = 'Para instalar de todos modos, bajo su responsabilidad: --skip-os-check. Detalles: docs/install/platforms.md'
        'cp_not_root' = 'No se ejecuta como root: use sudo para instalar (la comprobaci\u00f3n no lo necesita).'
        'sum_compat' = 'Compatibilidad'
        'cp_prereq_arch' = 'Las bases de datos de paquetes no est\u00e1n sincronizadas. Ejecute primero ''pacman -Syu'' (una actualizaci\u00f3n parcial no es compatible en Arch) y vuelva a ejecutar el instalador.'
        'cp_wdetected' = 'Detectado: {0} (build {1}), arq. {2}'
        'cp_wlist' = 'Versiones de Windows compatibles (amd64 y arm64; arm64 sin probar en hardware real):'
        'cp_r_arm32' = 'ARM de 32 bits (armv7) no es compatible con ToutWAF. Instale un sistema de 64 bits (Raspberry Pi OS 64 bits, Ubuntu o Debian arm64; Raspberry Pi 3, 4, 5 o Zero 2 W) y vuelva a ejecutar el instalador.'
        'cp_r_arm_userland32' = 'El kernel es de 64 bits pero el sistema (userland) es de 32 bits. ToutWAF necesita un sistema de 64 bits: reinstale con Raspberry Pi OS 64 bits (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) o Ubuntu / Debian arm64.'
        'cp_w_pi' = 'Raspberry Pi detectada: arm64 solo se ha probado bajo emulaci\u00f3n, no en hardware real. Ponga datos y registros en un SSD / disco USB en lugar de la tarjeta SD y evite la instalaci\u00f3n todo en uno con menos de 2 GB de RAM (vea docs/install/raspberry-pi.md).'
        'pf_title' = 'Comprobando lo que necesita esta m\u00e1quina'
        'pf_ok' = 'Nada estorba: los puertos que necesita ToutWAF est\u00e1n libres.'
        'pf_refused' = 'ToutWAF no se puede instalar en esta m\u00e1quina tal como est\u00e1. No se ha cambiado nada.'
        'pf_ok_warn' = 'Nada impide la instalaci\u00f3n, pero lea los puntos anteriores.'
        'pf_l_refuse' = 'rechazado'
        'pf_l_warn' = 'atenci\u00f3n'
        'pf_l_info' = 'nota'
        'pf_port_busy' = 'El puerto {0} ya lo usa {1}.'
        'pf_prog_other' = 'otro programa'
        'pf_prog_unknown' = 'otro programa (no se pudo leer su nombre)'
        'pf_act_web' = 'ToutWAF necesita los puertos {0} y {1} para proteger sus sitios. Detenga ese programa o mu\u00e9valo a otros puertos (ToutPanel, instalado junto a ToutWAF, coloca su servidor web en 8080 y 8443) y vuelva a ejecutar el instalador.'
        'pf_act_console' = 'La consola de ToutWAF necesita este puerto. Lib\u00e9relo o elija otro puerto para la consola (el instalador lo pregunta en su men\u00fa) y vuelva a ejecutar el instalador.'
        'pf_act_agent' = 'ToutWAF usa este puerto para los planos de datos y los agentes que se conectan a \u00e9l. Lib\u00e9relo y vuelva a ejecutar el instalador.'
        'pf_act_admin' = 'El plano de datos usa este puerto solo en esta m\u00e1quina, para su propia comprobaci\u00f3n de estado. Lib\u00e9relo y vuelva a ejecutar el instalador.'
        'pf_nostart' = '(ahora no se inicia nada, as\u00ed que solo se informa)'
        'pf_boot' = '{0} est\u00e1 instalado y arranca con la m\u00e1quina, aunque ahora est\u00e9 detenido. En el pr\u00f3ximo reinicio ocupar\u00eda los puertos {1} y {2} antes que ToutWAF.'
        'pf_act_boot' = 'Desact\u00edvelo para que no arranque con la m\u00e1quina, o mu\u00e9valo a otros puertos, antes de reiniciar la m\u00e1quina.'
        'pf_fw_cause' = 'Hay un cortafuegos ({0}) activo que no deja pasar los puertos {1} y {2}, y se ha indicado al instalador que no lo modifique.'
        'pf_fw_action' = 'Abra esos puertos en el cortafuegos o deje que lo haga el instalador (sin la opci\u00f3n --no-firewall). Si no, sus sitios no ser\u00e1n accesibles desde el exterior.'
        'pf_fwx_cause' = 'El cortafuegos de esta m\u00e1quina ({0}) rechaza las conexiones entrantes por defecto y no tiene ninguna regla para los puertos {1} y {2}.'
        'pf_fwx_action' = 'ToutWAF nunca modifica por s\u00ed mismo las reglas de este tipo de cortafuegos: abra esos puertos en su configuraci\u00f3n y compruebe sus sitios.'
        'pf_cp_cause' = 'No se puede alcanzar el plano de control {0} desde esta m\u00e1quina.'
        'pf_cp_action' = 'Compruebe la direcci\u00f3n, que el plano de control funciona y que su cortafuegos deja que esta m\u00e1quina lo alcance (puerto 9444 por defecto) y vuelva a ejecutar el instalador.'
        'pf_router_cause' = 'Esta m\u00e1quina tiene una direcci\u00f3n privada ({0}): probablemente est\u00e1 detr\u00e1s de un router.'
        'pf_router_action' = 'Una vez instalado, ToutWAF indica qu\u00e9 puertos redirigir a esta m\u00e1quina y proporciona los archivos para los routers habituales. No hay nada que preparar ahora.'
        'pf_skipped' = 'Se omiti\u00f3 la comprobaci\u00f3n del entorno como pidi\u00f3: lo que estorbe har\u00e1 fallar la instalaci\u00f3n o el arranque m\u00e1s adelante.'
        's_sysupdate' = 'Actualizando los paquetes del sistema (puede tardar varios minutos)'
        'su_skipped' = 'Los paquetes del sistema no se actualizan antes (TOUTWAF_SKIP_SYSUPDATE).'
        'su_recent' = 'Los paquetes del sistema se actualizaron hace menos de 6 horas: no se repite.'
        'su_dry' = 'los paquetes del sistema se actualizar\u00edan primero (se omite con TOUTWAF_SKIP_SYSUPDATE=1)'
        'su_nopm' = 'No hay un gestor de paquetes compatible para actualizar el sistema: se omite y la instalaci\u00f3n contin\u00faa.'
        'su_failed' = 'La actualizaci\u00f3n de los paquetes del sistema ha fallado (c\u00f3digo {0}); la instalaci\u00f3n contin\u00faa sin ella. Detalles: {1}. Soluci\u00f3n: ejecute usted mismo la actualizaci\u00f3n y lea su error (\u00bfrepositorio roto? \u00bfotro gestor de paquetes en ejecuci\u00f3n?), o vuelva a ejecutar este comando con TOUTWAF_SKIP_SYSUPDATE=1.'
        'su_reboot' = 'Hace falta reiniciar este servidor para terminar la actualizaci\u00f3n del sistema (nuevo kernel o bibliotecas). ToutWAF nunca lo reinicia por usted: h\u00e1galo cuando pueda.'
        'q_sysupdate' = '\u00bfActualizar primero los paquetes del sistema (recomendado)?'
        'pr_disk_full' = 'Solo quedan {0} MB libres en {1} (se necesitan al menos {2} MB): la instalaci\u00f3n no podr\u00eda terminar.'
        'pr_disk_full_a' = 'Libere espacio (cach\u00e9 de paquetes: apt-get clean o dnf clean all; registros antiguos: journalctl --vacuum-size=100M) y vuelva a ejecutar este comando. Para continuar de todos modos: TOUTWAF_SKIP_PREREQ=1.'
        'pr_disk_full_w_a' = 'Libere espacio (Liberador de espacio en disco, vaciar la papelera) y vuelva a ejecutar este comando. Para continuar de todos modos: $env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = 'Solo quedan {0} MB libres en {1} (unos {2} MB son lo c\u00f3modo).'
        'pr_disk_low_a' = 'Libere espacio o a\u00f1ada disco; la instalaci\u00f3n puede continuar.'
        'pr_dns' = 'Esta m\u00e1quina no puede resolver el nombre {0} (DNS).'
        'pr_dns_a' = 'Compruebe los servidores DNS (cat /etc/resolv.conf, resolvectl status), a\u00f1ada uno que funcione, por ejemplo nameserver 9.9.9.9, y vuelva a ejecutar este comando.'
        'pr_dns_w_a' = 'Compruebe los servidores DNS con ''ipconfig /all'', indique uno que funcione (por ejemplo 9.9.9.9) en la configuraci\u00f3n del adaptador de red y vuelva a ejecutar este comando.'
        'pr_clock' = 'El reloj de esta m\u00e1quina est\u00e1 desfasado {0} segundos respecto a la hora de Internet: los certificados TLS y las firmas fallan cuando el reloj es incorrecto.'
        'pr_clock_a' = 'Sincron\u00edcelo: timedatectl set-ntp true (o chronyc makestep), compruebe con timedatectl y vuelva a ejecutar este comando.'
        'pr_clock_w_a' = 'Sincron\u00edcelo: w32tm /resync (o Configuraci\u00f3n > Hora e idioma > Sincronizar ahora) y vuelva a ejecutar este comando.'
        'pr_ok' = 'El espacio en disco, el DNS y el reloj est\u00e1n en orden.'
        'cloud_https' = '--cloud-url debe ser una direcci\u00f3n https:// (el nodo nunca habla con la nube en claro).'
        'cloud_dp_only' = '--cloud-url instala un nodo de protecci\u00f3n: \u00faselo con --component dp (el valor por defecto en modo nube).'
        'cloud_need_token' = 'Se necesita un token de alta para conectar este nodo a su cuenta (--enroll-token; consola: Nodos > Agregar mi primer nodo).'
        'cloud_ca_local' = '--cloud-ca debe ser un archivo local.'
        'cloud_nolink' = 'Esta versi\u00f3n no incluye el enlace ToutWAF Cloud (toutwaf-cloudlink): actualice el instalador o use una versi\u00f3n m\u00e1s reciente.'
        'cloud_enrol_failed' = 'No se pudo dar de alta el nodo en su cuenta (vea las l\u00edneas anteriores). El token puede estar usado o caducado: cree uno nuevo en la consola.'
        'pf_cloud_action' = 'Permita que esta m\u00e1quina llegue a la direcci\u00f3n de su ToutWAF Cloud por el puerto 443 (solo saliente), o defina HTTPS_PROXY si se necesita un proxy. No hay que abrir nada de entrada.'
        's_db' = 'Preparando la base de datos'
        'db_choose' = '\u00bfQu\u00e9 base de datos debe usar ToutWAF?'
        'db_opt_pg' = 'PostgreSQL (recomendado)'
        'db_opt_pg_local' = 'Instalar PostgreSQL en esta m\u00e1quina (creado y configurado por usted)'
        'db_opt_pg_remote' = 'Usar un servidor PostgreSQL existente (se prueba y se prepara si lo permite)'
        'db_opt_sqlite' = 'SQLite (instalaci\u00f3n peque\u00f1a, un solo servidor)'
        'db_sqlite_note' = 'SQLite es un archivo en esta m\u00e1quina: v\u00e1lido para una instalaci\u00f3n peque\u00f1a en un servidor. No se puede compartir entre varios planos de control y no tiene replicaci\u00f3n. Podr\u00e1 pasar a PostgreSQL m\u00e1s tarde con: toutwaf-cp db migrate.'
        'db_q_host' = 'Host de PostgreSQL'
        'db_q_port' = 'Puerto'
        'db_q_name' = 'Nombre de la base de datos'
        'db_q_user' = 'Usuario de la base de datos'
        'db_q_pw' = 'Contrase\u00f1a de ese usuario (vac\u00eda si lo crea una cuenta de administrador)'
        'db_q_tls' = 'Modo TLS (disable, prefer, require, verify-ca, verify-full)'
        'db_q_ca' = 'Archivo del certificado de la CA del servidor (para verify-ca / verify-full)'
        'db_q_admin' = 'Cuenta de administrador que crea el usuario y la base (vac\u00edo = ya existen)'
        'db_q_adminpw' = 'Contrase\u00f1a de la cuenta de administrador (se usa una vez, nunca se guarda)'
        'db_hint' = 'Base de datos: SQLite (por defecto). Para un servidor o varios planos de control use --db postgres (--db-install-local lo instala por usted).'
        'db_no_pkg' = 'PostgreSQL no se puede instalar autom\u00e1ticamente en este sistema: instale usted el paquete del servidor y vuelva a ejecutar el instalador con --db postgres.'
        'db_install_failed' = 'Fall\u00f3 la instalaci\u00f3n del paquete PostgreSQL. El registro dice por qu\u00e9 (/var/log/toutwaf-install.log).'
        'db_init_failed' = 'No se pudo inicializar el cl\u00faster de PostgreSQL. El registro dice por qu\u00e9.'
        'db_start_failed' = 'PostgreSQL no arranca. Compruebe: systemctl status postgresql y el registro.'
        'db_too_old' = 'La versi\u00f3n de PostgreSQL instalada aqu\u00ed ({0}) es demasiado antigua: se requiere la versi\u00f3n 13 o posterior.'
        'db_exists' = 'Ya existe un usuario "{0}" o una base "{1}" que no cre\u00f3 este instalador: no se cambi\u00f3 nada. Elija otros nombres (--db-name, --db-user) o indique la conexi\u00f3n existente (--db-dsn-file).'
        'db_create_failed' = 'No se pudo crear el usuario o la base de datos. Lo creado se elimin\u00f3 de nuevo.'
        'db_rights' = 'La cuenta no tiene permiso para hacerlo. Las instrucciones anteriores son lo m\u00ednimo que un administrador del servidor debe ejecutar; luego vuelva a ejecutar el instalador.'
        'db_need_conn' = 'No se indic\u00f3 ninguna conexi\u00f3n al servidor PostgreSQL: use --db-dsn-file, o --db-host con --db-password-file, o --db-install-local.'
        'db_schema_failed' = 'No se pudieron crear las tablas en la base de datos. El registro dice por qu\u00e9.'
        'db_no_pgdump' = 'Falta pg_dump: la copia diaria de la base dar\u00e1 error hasta que se instale el paquete cliente de PostgreSQL.'
        'db_sum_engine' = 'Base de datos: {0}'
        'db_sum_local' = 'PostgreSQL funciona en esta m\u00e1quina (solo bucle local); base {0}, usuario {1} (sin derechos de administraci\u00f3n)'
        'db_sum_remote' = 'Servidor PostgreSQL existente; base {0}, usuario {1}'
        'db_sum_schema' = 'Esquema: {0}'
        'db_sum_secret' = 'La conexi\u00f3n (con su contrase\u00f1a) est\u00e1 en {0}, legible solo por el servicio ToutWAF'
        'db_sum_backup' = 'Cada noche se ejecuta un pg_dump verificado (se conservan 7); estado en la consola, Salud'
        'db_sum_nobackup' = 'Sin copia autom\u00e1tica de la base: programe pg_dump o use la copia de su proveedor de base de datos'
        'db_sum_sqlite' = 'Base de datos: SQLite, un archivo en esta m\u00e1quina (instalaci\u00f3n peque\u00f1a). Pasar a PostgreSQL m\u00e1s tarde: toutwaf-cp db migrate'
        's_extras' = 'Extras: agente de Windows y programas del antivirus'
        's_extras_ok' = 'Extras instalados: {0} programas en {1}'
        's_extras_sha' = 'Extras verificados: {0} archivo(s), {1} MiB (SHA-256 y firma)'
        's_extras_unchecked' = 'Extras tomados tal cual, sin SHA256SUMS para verificarlos: {0}'
        'w_extras_dl' = 'No se pudieron descargar los extras ({0}). ToutWAF funciona sin ellos, pero esta consola no ofrecer\u00e1 Windows ni el antivirus hasta que se instalen.'
        'w_extras_sum' = 'Los extras {0} no coinciden con su SHA-256 del SHA256SUMS firmado: NO se instalaron.'
        'w_extras_bad' = 'El archivo de extras {0} no es un archivo de extras v\u00e1lido: NO se instal\u00f3.'
        'w_extras_ver' = 'Los extras son de la versi\u00f3n {0}, esta instalaci\u00f3n es {1}: NO se instalaron.'
        'w_extras_inc' = 'La versi\u00f3n lista {0} parte(s) de los extras pero indica {1}: la publicaci\u00f3n est\u00e1 da\u00f1ada, los extras NO se instalaron.'
        'w_extras_nofile' = 'El archivo de extras {0} no existe.'
        'w_extras_none' = 'Esta versi\u00f3n no incluye extras: esta consola no ofrecer\u00e1 Windows ni el antivirus.'
        'w_extras_todo' = 'Extras no instalados. Cuando la red lo permita, ejecute como root: {0}'
        'extras_needs_cp' = 'Los extras pertenecen al plano de control: no est\u00e1 instalado en esta m\u00e1quina.'
        'extras_other_release' = 'La versi\u00f3n publicada ({0}) no es la instalada ({1}): los extras vienen con ella. Ejecute --update.'
        'st_extras_ok' = 'Extras: instalados (agente de Windows, programas del antivirus)'
        'st_extras_none' = 'Extras ausentes: Windows y el antivirus no se ofrecen. Ejecute como root: {0}'
    }
    'de' = @{
        'tagline' = 'Schutz f\u00fcr Webanwendungen und APIs'
        'menu_title' = 'Was m\u00f6chten Sie tun?'
        'opt_install' = 'Installieren (Control Plane + Data Plane + Konsole)'
        'opt_install_d' = 'Alles auf diesem Rechner: Web-Konsole, Richtlinienspeicher und Reverse-Proxy / WAF.'
        'opt_cp' = 'Nur die Control Plane installieren'
        'opt_cp_d' = 'Web-Konsole, API und Richtlinienspeicher. Data Planes (Knoten) treten sp\u00e4ter bei.'
        'opt_dp' = 'Nur eine Data Plane installieren'
        'opt_dp_d' = 'Reverse-Proxy- / WAF-Knoten, der einer bestehenden Control Plane beitritt (fragt URL und Registrierungstoken ab).'
        'opt_update' = 'Aktualisieren'
        'opt_update_d' = 'L\u00e4dt eine neuere Version, pr\u00fcft sie (SHA-256 / sigstore), sichert, beh\u00e4lt Konfiguration und Daten und macht bei Fehlern r\u00fcckg\u00e4ngig.'
        'opt_uninstall' = 'Deinstallieren'
        'opt_uninstall_d' = 'Entfernt ToutWAF; Sie w\u00e4hlen, ob Konfiguration, Daten und Logs behalten oder gel\u00f6scht werden.'
        'opt_status' = 'Status und Gesundheitspr\u00fcfung'
        'opt_status_d' = 'Installierte Versionen, Dienste, lauschende Ports und Health-Endpunkte.'
        'opt_links' = 'Panel-Links erneut anzeigen'
        'opt_links_d' = 'Panel-URLs, einmaliger Einrichtungslink und die in der Firewall zu \u00f6ffnenden Ports.'
        'opt_quit' = 'Beenden'
        'choice' = 'Ihre Wahl'
        'invalid_choice' = 'Ung\u00fcltige Auswahl.'
        'state_installed' = 'Installiert: {0}'
        'state_none' = 'ToutWAF ist auf diesem Rechner nicht installiert.'
        'cfg_title' = 'Installationsoptionen (Eingabe = Standard)'
        'q_cp_url' = 'URL der Control Plane (z. B. https://cp.example.com:9444)'
        'q_token' = 'Registrierungstoken (Konsole: Knoten > Knoten hinzuf\u00fcgen)'
        'q_cp_ca' = 'PEM-Datei der CA / des Zertifikats der Control Plane (leer = Systemspeicher)'
        'q_cp_port' = 'Konsolen-Port'
        'q_http_port' = 'HTTP-Port'
        'q_https_port' = 'HTTPS-Port'
        'q_public_host' = '\u00d6ffentlicher Hostname oder IP-Adresse (leer = automatisch)'
        'q_firewall' = 'Firewall automatisch \u00f6ffnen (firewalld / ufw)?'
        'q_boot' = 'Dienste beim Systemstart starten?'
        'q_channel' = 'Release-Kanal (stable / dev)'
        'q_bindir' = 'Installationsverzeichnis'
        'q_confirm' = 'Installation starten?'
        'q_purge' = 'Auch Konfiguration, Daten und Logs l\u00f6schen? (Nein = behalten)'
        'q_confirm_un' = 'ToutWAF wirklich deinstallieren?'
        'aborted' = 'Abgebrochen.'
        'root_required' = 'Als root ausf\u00fchren (sudo bash install.sh).'
        's_prereq' = 'Voraussetzungen installieren'
        's_fetch' = 'ToutWAF {0} ({1}) wird heruntergeladen'
        's_sha' = 'SHA-256 gepr\u00fcft'
        's_sig' = 'cosign-Signatur gepr\u00fcft'
        'w_nocosign' = 'cosign fehlt: Signatur nicht gepr\u00fcft (nur Pr\u00fcfsumme)'
        's_user' = 'Dienstkonto und Verzeichnisse anlegen'
        's_bin' = 'Programme installieren'
        's_cfg' = 'Konfiguration schreiben (vorhandene Dateien bleiben)'
        's_units' = 'systemd-Units und Systemoptimierung installieren'
        's_selinux' = 'SELinux konfigurieren'
        'q_console_from' = 'Konsole nur f\u00fcr dieses Netz freigeben (CIDR, z. B. 203.0.113.0/24; leer = alle)'
        'q_console_from_bad' = 'Keine Adresse und kein CIDR (0.0.0.0/0 entspricht leer): der Konsolenport bleibt f\u00fcr alle offen.'
        'fw_console_note' = 'Die Konsole (Port {0}) enth\u00e4lt die Admin-Anmeldung: sie f\u00fcr das ganze Internet zu \u00f6ffnen ist bequem, aber exponiert.'
        'fw_console_open' = 'Konsolenport {0} ist f\u00fcr alle offen: mit --console-from CIDR oder in der Konsole (Einstellungen > Firewall) einschr\u00e4nken'
        'fw_console_from' = 'Konsolenport {0} ist nur f\u00fcr {1} offen'
        'fw_none' = 'Keine aktive Firewall (firewalld / ufw / nftables / iptables) gefunden: nichts filtert den Verkehr, keine Ports zu \u00f6ffnen'
        'fw_manual' = 'Die Firewall {0} wird vom Installer nicht ver\u00e4ndert: f\u00fchren Sie diese Befehle selbst aus'
        'fw_failed' = 'Die Firewall konnte nicht konfiguriert werden: {0}'
        'home_fresh' = 'Neuinstallation: alles liegt unter {0} (bin, conf, data, logs)'
        'home_legacy' = 'Bestehende Installation erkannt: ihre Pfade bleiben (bin {0}, conf {1}, data {2}). Nichts wird verschoben; --home DIR f\u00fcr das neue Layout.'
        'home_explicit_legacy' = '--home {0} wurde angegeben, obwohl in {1} eine Installation existiert: deren Daten werden NICHT verschoben'
        'home_bad' = '--home muss ein absoluter Pfad sein (Buchstaben, Ziffern, . _ - + /), nicht / und nicht unter /proc /sys /dev: {0}'
        'home_noexec' = '{0} liegt auf einem noexec-Mount: die Programme k\u00f6nnten dort nicht laufen, w\u00e4hlen Sie ein anderes --home'
        's_fw' = 'Firewall konfigurieren'
        's_boot' = 'Panel vorbereiten (Administratorkonto, sicherer Pfad)'
        's_start' = 'Dienste starten'
        's_health' = 'Warten auf gesunde Dienste'
        's_backup' = 'Konfiguration und Daten sichern'
        'w_rollback' = 'Die neue Version arbeitet nicht fehlerfrei: R\u00fcckkehr zur vorherigen'
        'up_to_date' = 'Bereits aktuell ({0})'
        'not_installed' = 'ToutWAF ist nicht installiert: nichts zu aktualisieren.'
        'st_channel' = 'Kanal: {0}'
        'st_latest' = 'Neueste verf\u00fcgbare Version: {0}'
        'st_newer' = 'Update verf\u00fcgbar: mit --update ausf\u00fchren'
        'e_yanked' = 'Version {0} wurde zur\u00fcckgezogen (yanked) und darf nicht installiert werden. Mit --update die aktuelle Version holen, oder --force zum \u00dcbergehen.'
        'e_nover' = 'Auf dem Kanal {0} ist noch keine Version ver\u00f6ffentlicht, es gibt also nichts zu installieren. ToutWAF wurde weder installiert noch ver\u00e4ndert. Um vom Kanal {1} zu installieren, starten Sie das Installationsprogramm erneut mit -Channel {2}.'
        'e_installer_old' = 'Dieses Installationsprogramm ist f\u00fcr diese Version zu alt (ben\u00f6tigt Version {0}): erneut von der Kanal-URL laden.'
        'up_rebuilt' = 'Gleiche Version, neuer Build: installiert {0}, verf\u00fcgbar {1}. Aktualisierung l\u00e4uft.'
        'st_newbuild' = 'gleiche Version, neuer Build verf\u00fcgbar: erneut mit {0} ausf\u00fchren'
        'st_nochannel' = 'Neueste verf\u00fcgbare Version: in diesem Kanal ist noch nichts ver\u00f6ffentlicht'
        'w_mirror' = 'Der \u00f6ffentliche Spiegel hat Dateien geliefert, die nicht zusammenpassen ({0}): vermutlich wird er nach einer Ver\u00f6ffentlichung noch aktualisiert. Der Kanal wird einmal neu gelesen.'
        'e_mismatch' = 'Pr\u00fcfsumme stimmt nicht f\u00fcr {0} ({1}): Die heruntergeladene Datei passt nicht zur ver\u00f6ffentlichten Pr\u00fcfsumme, daher wurde nichts installiert oder ge\u00e4ndert. Direkt nach einer Ver\u00f6ffentlichung kann der \u00f6ffentliche Spiegel einige Minuten lang die vorherigen Dateien liefern: Warten Sie f\u00fcnf Minuten und starten Sie das Installationsprogramm erneut. Tritt es erneut auf, installieren Sie nicht: Die Ver\u00f6ffentlichung ist besch\u00e4digt.'
        'e_downgrade' = 'Die neueste Version {0} des Kanals {1} ist \u00e4lter als die installierte {2}: --force zum Downgrade.'
        's_sigok' = 'Release-Signatur gepr\u00fcft, Schl\u00fcssel {0}'
        'w_sigold' = 'Version {0} wurde ohne Signatur ver\u00f6ffentlicht (Versionen vor 0.2.0-dev.7 sind unsigniert): nur SHA-256 wurde gepr\u00fcft, die Signatur konnte nicht gepr\u00fcft werden'
        'w_sigskip' = 'Release-Signatur NICHT gepr\u00fcft: openssl.exe wurde im PATH nicht gefunden (Windows hat keine eingebaute Ed25519-Pr\u00fcfung), nur SHA-256 wurde gepr\u00fcft. OpenSSL 3 installieren und erneut ausf\u00fchren, um mit Schl\u00fcssel {0} zu pr\u00fcfen'
        'done' = 'Fertig.'
        'failed' = 'Fehlgeschlagen'
        'log_hint' = 'Vollst\u00e4ndiges Protokoll: {0}'
        'dry_done' = 'Testlauf: nichts wurde ge\u00e4ndert.'
        'sum_title' = 'Zusammenfassung der Installation'
        'sum_panel' = 'Panel-Links'
        'sum_tls_note' = 'Nur HTTPS. Das Zertifikat ist selbstsigniert, bis Sie ein eigenes installieren: der Browser warnt.'
        'sum_local' = 'Lokale Adressen'
        'sum_public' = '\u00d6ffentliche Adresse'
        'sum_public_unknown' = 'Die \u00f6ffentliche IP konnte nicht ermittelt werden (offline oder blockiert). Verwenden Sie die \u00f6ffentliche IP oder den DNS-Namen Ihres Servers statt der lokalen Adressen oder starten Sie mit --public-host neu.'
        'sum_admin' = 'Administratorkonto'
        'sum_user' = 'Benutzername'
        'sum_password' = 'Passwort'
        'sum_pw_once' = 'wird nur EINMAL angezeigt - \u00e4nderbar unter Einstellungen > Zugang / Konto'
        'sum_pw_unchanged' = 'unver\u00e4ndert (wird nie neu erzeugt). Zur\u00fccksetzen mit: toutwaf-cp admin reset-password --user {0}'
        'sum_setup' = 'Einmaliger Einrichtungslink'
        'sum_setup_note' = '\u00d6ffnen Sie ihn, um Panel-Link, Konto und Passwort im Web-Assistenten festzulegen.'
        'p_dpapi_warn' = 'Port 9444 (Data-Plane-API) ist NICHT ge\u00f6ffnet: nur von Ihren Data-Plane-Knoten freigeben'
        'p_dpapi_only' = '9444/tcp nur von Ihren Data Planes, z. B.:'
        'sum_setup_none' = 'Diesmal kein Einrichtungslink (bereits ausgestellt oder Konto bestand schon). Neu erzeugen: toutwaf-cp setup-link --regenerate'
        'sum_ports' = 'In der Firewall zu \u00f6ffnende Ports'
        'sum_cmds' = 'Befehle'
        'sum_cloud' = 'Cloud / Hosting: \u00d6ffnen Sie diese Ports auch in der Sicherheitsgruppe / Netzwerk-ACL des Anbieters.'
        'sum_file' = 'Zusammenfassung gespeichert (nur root): {0}'
        'sum_fallback' = 'Diese Control Plane hat noch kein ''bootstrap''-Kommando: \u00f6ffnen Sie die Konsolen-URL und folgen Sie der Einrichtungsseite.'
        'sum_node_hint' = 'Um diesen Knoten \u00fcber die Konsole zu verwalten: Knoten > Knoten hinzuf\u00fcgen, dann control_plane.url / enroll_token in {0} setzen.'
        'q_fwmodule' = 'Soll ToutWAF auch die Firewall dieses Rechners verwalten?'
        'fwmod_n1' = 'Optionales Modul, aus, au\u00dfer Sie sagen ja. W\u00e4hrend der Installation wird nichts angewendet: Sie pr\u00fcfen jede \u00c4nderung in der Konsole.'
        's_bkclient' = 'ToutWAF-Backup-Client wird installiert (Signatur gepr\u00fcft)'
        'bkc_done' = 'ToutWAF-Backup-Client installiert. Weiter: Konsole, Backups > Backup-Server, um einen Server zu koppeln.'
        'bkc_fail' = 'Der ToutWAF-Backup-Client wurde NICHT installiert ({0}). Die Installation l\u00e4uft weiter; sp\u00e4ter mit --with-backup-client nachholen.'
        'bkc_nokey' = 'Der ToutWAF-Backup-Client wurde NICHT installiert: kein \u00f6ffentlicher Release-Schl\u00fcssel. Angeben mit --backup-client-pubkey (oder TOUTWAF_BACKUP_PUBKEY oder der Datei backup-release.pub im Konfigurationsordner); ohne gepr\u00fcfte Signatur wird nichts installiert.'
        'bkc_badsig' = 'Der ToutWAF-Backup-Client wurde NICHT installiert: die Signatur der Version ist NICHT g\u00fcltig. Es wurde nichts installiert.'
        'tele_on' = 'Telemetrie: Standardm\u00e4\u00dfig teilt ToutWAF mit dem Herausgeberbereich (app.toutwaf.com) die blockierten Angriffe (Adresse des Angreifers, Land, Angriffsart, Regel), aggregierte Zahlen und die Hostnamen der gesch\u00fctzten Sites. Niemals den Inhalt von Anfragen und niemals legitime Besucher. Mit einem Klick in der Konsole abschaltbar (Einstellungen, Datenschutz und Telemetrie), oder installieren Sie mit --no-telemetry (oder TOUTWAF_TELEMETRY=0) f\u00fcr Null-Telemetrie. Details: docs/confidentialite-telemetrie.md'
        'tele_off' = 'Telemetrie: Null-Telemetrie wurde angefordert (--no-telemetry / TOUTWAF_TELEMETRY=0). Es wird nichts an den Herausgeberbereich gesendet und nichts von ihm empfangen; die Konsole startet mit aktivem Schalter \u201eNull-Telemetrie\u201c. Sie k\u00f6nnen das sp\u00e4ter in der Konsole \u00e4ndern (Einstellungen, Datenschutz und Telemetrie).'
        'fwmod_n2' = 'Jede \u00c4nderung l\u00e4uft als Test mit Countdown und wird von selbst zur\u00fcckgenommen, wenn Sie sie nicht behalten; ein Aussperrschutz lehnt jede Regel ab, die SSH oder die Konsole kappen w\u00fcrde.'
        'fwmod_n3' = 'Das ist nicht die Frage davor, die nur die von ToutWAF ben\u00f6tigten Ports in der System-Firewall \u00f6ffnet (--no-firewall).'
        's_fwmod' = 'Firewall-Modul wird aktiviert (keine Regel angewendet)'
        'fwmod_done' = 'Firewall-Modul aktiviert. Es wurde nichts angewendet: \u00d6ffnen Sie Firewall in der Konsole, um Regeln zu pr\u00fcfen und zu testen.'
        'fwmod_fail' = 'Das Firewall-Modul konnte nicht aktiviert werden ({0}). Die Installation l\u00e4uft weiter; aktivieren Sie es sp\u00e4ter unter Einstellungen > Module.'
        's_link' = 'Data Plane wird mit der Konsole verbunden'
        'dp_link_ok' = 'Data Plane automatisch mit der Konsole verbunden: nichts von Hand zu konfigurieren.'
        'dp_link_same' = 'Data Plane bereits mit der Konsole verbunden; die Konfiguration blieb unver\u00e4ndert.'
        'dp_link_fixed' = 'Data-Plane-Konfiguration repariert (doppelte control_plane-Bl\u00f6cke zu einem zusammengef\u00fchrt); die vorherige Datei blieb erhalten.'
        'dp_link_remote' = 'Die Data Plane dieses Rechners ist f\u00fcr eine andere Konsole konfiguriert und blieb unver\u00e4ndert.'
        'dp_link_fail' = 'Die Data Plane konnte nicht automatisch mit der Konsole verbunden werden: {0}'
        'dp_link_fail_hint' = 'Die Data Plane beh\u00e4lt ihre eigenst\u00e4ndige Konfiguration; Sites antworten mit HTTP 421, bis sie verbunden ist. Beheben Sie die oben genannte Ursache und starten Sie diesen Installer erneut: Er verbindet den Knoten selbst.'
        'st_title' = 'Status'
        'st_healthy' = 'gesund'
        'st_unhealthy' = 'NICHT gesund'
        'st_active' = 'aktiv'
        'st_inactive' = 'inaktiv'
        'st_listening' = 'lauscht'
        'st_closed' = 'lauscht nicht'
        'un_title' = 'ToutWAF wird deinstalliert'
        'un_kept' = 'Konfiguration bleibt in {0}, Daten in {1} (--purge zum L\u00f6schen).'
        'un_purged' = 'Konfiguration, Daten und Logs gel\u00f6scht.'
        'p_console' = 'Web-Konsole + API'
        'p_http' = 'HTTP (Reverse-Proxy)'
        'p_https' = 'HTTPS (Reverse-Proxy)'
        'p_dpapi' = 'Data-Plane-API: NUR wenn Data Planes auf ANDEREN Hosts laufen (auf deren IPs beschr\u00e4nken)'
        'w_fw_manual' = 'Port {0}/tcp wurde nicht automatisch ge\u00f6ffnet: siehe Befehle in der Zusammenfassung.'
        'need_cp' = 'Mit einem Registrierungstoken wird die URL einer Control Plane ben\u00f6tigt.'
        'cp_title' = 'Systemkompatibilit\u00e4t'
        'cp_detected' = 'Erkannt: {0}, Arch {1}, glibc {2}, systemd {3}, Kernel {4}'
        'cp_ok' = 'Kompatibel: {0} ({1})'
        'cp_tested' = 'getestet'
        'cp_expected' = 'erwartet'
        'cp_w_like' = '{0} steht nicht in der Kompatibilit\u00e4tstabelle: wird als Familie {1} behandelt (erwartet). Es geht weiter.'
        'cp_w_newer' = '{0} {1} ist neuer als die gelisteten Versionen: noch nicht validiert (erwartet). Es geht weiter.'
        'cp_w_unlisted' = '{0} {1} steht nicht in der Tabelle: wird als erwartet behandelt. Es geht weiter.'
        'cp_w_nover' = '{0} meldet keine Version (Rolling oder Testing): wird als erwartet behandelt. Es geht weiter.'
        'cp_w_glibc' = 'Die glibc-Version konnte nicht ermittelt werden; es geht weiter.'
        'cp_w_skip' = '--skip-os-check: die Kompatibilit\u00e4tspr\u00fcfung wird \u00fcbergangen. Dieses System wird NICHT unterst\u00fctzt: Fortfahren auf eigenes Risiko.'
        'cp_w_stage' = 'Staging (--destdir): das Kompatibilit\u00e4tsergebnis ist nur informativ, nichts wird abgelehnt.'
        'cp_refused' = 'Dieses System ist nicht mit ToutWAF kompatibel:'
        'cp_r_old' = '{0} {1} ist \u00e4lter als die minimal unterst\u00fctzte Version ({2}).'
        'cp_r_eol' = '{0} {1} ist am Ende seines Lebenszyklus oder seine glibc / systemd ist zu alt.'
        'cp_r_glibc' = 'glibc {0} gefunden: {1} oder neuer ist erforderlich.'
        'cp_r_musl' = 'musl libc gefunden: glibc {0} oder neuer ist erforderlich.'
        'cp_r_init' = '{0} {1} verwendet kein systemd, das ToutWAF ben\u00f6tigt.'
        'cp_r_immutable' = '{0} {1} hat ein unver\u00e4nderliches Root-Dateisystem (nicht unterst\u00fctzt).'
        'cp_r_layout' = '{0} {1} folgt nicht der Linux-Standardverzeichnisstruktur (nicht unterst\u00fctzt).'
        'cp_r_arch' = 'Die Architektur {0} wird nicht unterst\u00fctzt (unterst\u00fctzt: {1}).'
        'cp_r_distro_arch' = '{0} {1} l\u00e4uft auf einer Architektur ohne ToutWAF-Build.'
        'cp_r_systemd' = 'systemd l\u00e4uft nicht als Init-System (/run/systemd/system fehlt): es wird f\u00fcr die Dienste ben\u00f6tigt.'
        'cp_r_systemd_old' = 'systemd {0} gefunden: {1} oder neuer ist erforderlich.'
        'cp_r_kernel' = 'Linux-Kernel {0} gefunden: {1} oder neuer ist erforderlich.'
        'cp_r_unknown' = 'Die Distribution ''{0}'' ist unbekannt und nennt keine bekannte Familie (ID_LIKE=''{1}'').'
        'cp_r_noosr' = '/etc/os-release fehlt: die Distribution kann nicht erkannt werden.'
        'cp_nochange' = 'An diesem System wurde nichts ge\u00e4ndert.'
        'cp_list' = 'Kompatible Systeme (amd64 und arm64, glibc {0} oder neuer, systemd {1} oder neuer):'
        'cp_rolling' = 'Rolling'
        'cp_any' = 'jede Version'
        'cp_override' = 'Trotzdem installieren, auf eigenes Risiko: --skip-os-check. Details: docs/install/platforms.md'
        'cp_not_root' = 'Nicht als root ausgef\u00fchrt: zum Installieren sudo verwenden (die Pr\u00fcfung selbst braucht kein root).'
        'sum_compat' = 'Kompatibilit\u00e4t'
        'cp_prereq_arch' = 'Die Paketdatenbanken sind nicht synchronisiert. F\u00fchren Sie zuerst ''pacman -Syu'' aus (ein Teil-Update wird unter Arch nicht unterst\u00fctzt) und starten Sie den Installer erneut.'
        'cp_wdetected' = 'Erkannt: {0} (Build {1}), Arch {2}'
        'cp_wlist' = 'Kompatible Windows-Versionen (amd64 und arm64; arm64 nicht auf echter Hardware getestet):'
        'cp_r_arm32' = '32-Bit-ARM (armv7) wird von ToutWAF nicht unterst\u00fctzt. Installieren Sie ein 64-Bit-System (Raspberry Pi OS 64 Bit, Ubuntu oder Debian arm64; Raspberry Pi 3, 4, 5 oder Zero 2 W) und starten Sie den Installer erneut.'
        'cp_r_arm_userland32' = 'Der Kernel ist 64-Bit, das System (Userland) aber 32-Bit. ToutWAF ben\u00f6tigt ein 64-Bit-System: Installieren Sie Raspberry Pi OS 64 Bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) oder Ubuntu / Debian arm64 neu.'
        'cp_w_pi' = 'Raspberry Pi erkannt: arm64 wurde nur unter Emulation getestet, nicht auf echter Hardware. Legen Sie Daten und Logs auf eine SSD / ein USB-Laufwerk statt auf die SD-Karte und vermeiden Sie die All-in-one-Installation unter 2 GB RAM (siehe docs/install/raspberry-pi.md).'
        'pf_title' = 'Pr\u00fcfung dessen, was dieser Rechner braucht'
        'pf_ok' = 'Nichts steht im Weg: Die Ports, die ToutWAF braucht, sind frei.'
        'pf_refused' = 'ToutWAF kann auf diesem Rechner so nicht installiert werden. Es wurde nichts ge\u00e4ndert.'
        'pf_ok_warn' = 'Nichts verhindert die Installation, aber lesen Sie die Punkte oben.'
        'pf_l_refuse' = 'abgelehnt'
        'pf_l_warn' = 'Hinweis'
        'pf_l_info' = 'Info'
        'pf_port_busy' = 'Port {0} wird bereits von {1} verwendet.'
        'pf_prog_other' = 'ein anderes Programm'
        'pf_prog_unknown' = 'ein anderes Programm (sein Name konnte nicht gelesen werden)'
        'pf_act_web' = 'ToutWAF braucht die Ports {0} und {1}, um Ihre Sites zu sch\u00fctzen. Beenden Sie dieses Programm oder verlegen Sie es auf andere Ports (ToutPanel, neben ToutWAF installiert, legt seinen Webserver auf 8080 und 8443) und starten Sie den Installer erneut.'
        'pf_act_console' = 'Die Konsole von ToutWAF braucht diesen Port. Geben Sie ihn frei oder w\u00e4hlen Sie einen anderen Konsolen-Port (der Installer fragt in seinem Men\u00fc danach) und starten Sie den Installer erneut.'
        'pf_act_agent' = 'ToutWAF nutzt diesen Port f\u00fcr die Data Planes und Agenten, die sich damit verbinden. Geben Sie ihn frei und starten Sie den Installer erneut.'
        'pf_act_admin' = 'Die Data Plane nutzt diesen Port nur auf diesem Rechner, f\u00fcr ihre eigene Zustandspr\u00fcfung. Geben Sie ihn frei und starten Sie den Installer erneut.'
        'pf_nostart' = '(es wird jetzt nichts gestartet, daher nur ein Hinweis)'
        'pf_boot' = '{0} ist installiert und startet mit dem Rechner, obwohl es gerade gestoppt ist. Beim n\u00e4chsten Neustart w\u00fcrde es die Ports {1} und {2} vor ToutWAF belegen.'
        'pf_act_boot' = 'Deaktivieren Sie den Autostart oder verlegen Sie es auf andere Ports, bevor der Rechner neu startet.'
        'pf_fw_cause' = 'Eine Firewall ({0}) ist aktiv und l\u00e4sst die Ports {1} und {2} nicht durch, und der Installer soll sie nicht \u00e4ndern.'
        'pf_fw_action' = '\u00d6ffnen Sie diese Ports in der Firewall oder lassen Sie den Installer es tun (ohne die Option --no-firewall). Sonst sind Ihre Sites von au\u00dfen nicht erreichbar.'
        'pf_fwx_cause' = 'Die Firewall dieses Rechners ({0}) lehnt eingehende Verbindungen standardm\u00e4\u00dfig ab und hat keine Regel f\u00fcr die Ports {1} und {2}.'
        'pf_fwx_action' = 'ToutWAF \u00e4ndert die Regeln dieser Art von Firewall nie selbst: \u00d6ffnen Sie diese Ports in deren Konfiguration und pr\u00fcfen Sie dann Ihre Sites.'
        'pf_cp_cause' = 'Die Control Plane {0} ist von diesem Rechner aus nicht erreichbar.'
        'pf_cp_action' = 'Pr\u00fcfen Sie die Adresse, ob die Control Plane l\u00e4uft und ob deren Firewall diesen Rechner durchl\u00e4sst (standardm\u00e4\u00dfig Port 9444), und starten Sie den Installer erneut.'
        'pf_router_cause' = 'Dieser Rechner hat eine private Adresse ({0}): Er steht wahrscheinlich hinter einem Router.'
        'pf_router_action' = 'Nach der Installation zeigt ToutWAF, welche Ports an diesen Rechner weitergeleitet werden m\u00fcssen, und liefert die Dateien f\u00fcr g\u00e4ngige Router. Jetzt ist nichts vorzubereiten.'
        'pf_skipped' = 'Die Umgebungspr\u00fcfung wurde auf Ihren Wunsch \u00fcbersprungen: Was im Weg steht, l\u00e4sst die Installation oder den Start sp\u00e4ter scheitern.'
        's_sysupdate' = 'Systempakete werden aktualisiert (das kann einige Minuten dauern)'
        'su_skipped' = 'Die Systempakete werden nicht vorher aktualisiert (TOUTWAF_SKIP_SYSUPDATE).'
        'su_recent' = 'Die Systempakete wurden vor weniger als 6 Stunden aktualisiert: keine Wiederholung.'
        'su_dry' = 'die Systempakete w\u00fcrden zuerst aktualisiert (\u00fcberspringen mit TOUTWAF_SKIP_SYSUPDATE=1)'
        'su_nopm' = 'Kein unterst\u00fctzter Paketmanager f\u00fcr die Systemaktualisierung: \u00fcbersprungen, die Installation l\u00e4uft weiter.'
        'su_failed' = 'Die Aktualisierung der Systempakete ist fehlgeschlagen (Code {0}); die Installation l\u00e4uft ohne sie weiter. Details: {1}. Abhilfe: F\u00fchren Sie die Aktualisierung selbst aus und lesen Sie die Fehlermeldung (defektes Repository? l\u00e4uft ein anderer Paketmanager?), oder starten Sie diesen Befehl erneut mit TOUTWAF_SKIP_SYSUPDATE=1.'
        'su_reboot' = 'Zum Abschluss der Systemaktualisierung ist ein Neustart dieses Servers n\u00f6tig (neuer Kernel oder neue Bibliotheken). ToutWAF startet ihn nie f\u00fcr Sie neu: Tun Sie es, wenn es passt.'
        'q_sysupdate' = 'Zuerst die Systempakete aktualisieren (empfohlen)?'
        'pr_disk_full' = 'Nur {0} MB sind frei auf {1} (mindestens {2} MB werden ben\u00f6tigt): Die Installation k\u00f6nnte nicht abgeschlossen werden.'
        'pr_disk_full_a' = 'Schaffen Sie Platz (Paket-Cache: apt-get clean oder dnf clean all; alte Logs: journalctl --vacuum-size=100M) und f\u00fchren Sie diesen Befehl erneut aus. Trotzdem fortfahren: TOUTWAF_SKIP_PREREQ=1.'
        'pr_disk_full_w_a' = 'Schaffen Sie Platz (Datentr\u00e4gerbereinigung, Papierkorb leeren) und f\u00fchren Sie diesen Befehl erneut aus. Trotzdem fortfahren: $env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = 'Nur {0} MB sind frei auf {1} (etwa {2} MB sind komfortabel).'
        'pr_disk_low_a' = 'Schaffen Sie Platz oder f\u00fcgen Sie Speicher hinzu; die Installation kann weiterlaufen.'
        'pr_dns' = 'Dieser Rechner kann den Namen {0} nicht aufl\u00f6sen (DNS).'
        'pr_dns_a' = 'Pr\u00fcfen Sie die DNS-Server (cat /etc/resolv.conf, resolvectl status), tragen Sie einen funktionierenden ein, z. B. nameserver 9.9.9.9, und f\u00fchren Sie diesen Befehl erneut aus.'
        'pr_dns_w_a' = 'Pr\u00fcfen Sie die DNS-Server mit ''ipconfig /all'', tragen Sie in den Einstellungen des Netzwerkadapters einen funktionierenden ein (z. B. 9.9.9.9) und f\u00fchren Sie diesen Befehl erneut aus.'
        'pr_clock' = 'Die Uhr dieses Rechners weicht um {0} Sekunden von der Internetzeit ab: TLS-Zertifikate und Signaturen schlagen fehl, wenn die Uhr falsch geht.'
        'pr_clock_a' = 'Synchronisieren Sie sie: timedatectl set-ntp true (oder chronyc makestep), pr\u00fcfen Sie mit timedatectl und f\u00fchren Sie diesen Befehl erneut aus.'
        'pr_clock_w_a' = 'Synchronisieren Sie sie: w32tm /resync (oder Einstellungen > Zeit und Sprache > Jetzt synchronisieren) und f\u00fchren Sie diesen Befehl erneut aus.'
        'pr_ok' = 'Speicherplatz, DNS und Uhr sind in Ordnung.'
        'cloud_https' = '--cloud-url muss eine https://-Adresse sein (der Knoten spricht nie unverschl\u00fcsselt mit der Cloud).'
        'cloud_dp_only' = '--cloud-url installiert einen Schutzknoten: mit --component dp verwenden (Standard im Cloud-Modus).'
        'cloud_need_token' = 'Zum Verbinden dieses Knotens mit Ihrem Konto ist ein Registrierungstoken n\u00f6tig (--enroll-token; Konsole: Knoten > Meinen ersten Knoten hinzuf\u00fcgen).'
        'cloud_ca_local' = '--cloud-ca muss eine lokale Datei sein.'
        'cloud_nolink' = 'Diese Version enth\u00e4lt die ToutWAF-Cloud-Verbindung (toutwaf-cloudlink) nicht: Installer aktualisieren oder neuere Version verwenden.'
        'cloud_enrol_failed' = 'Der Knoten konnte nicht in Ihrem Konto registriert werden (siehe Zeilen oben). Das Token ist vielleicht verbraucht oder abgelaufen: Erstellen Sie in der Konsole ein neues.'
        'pf_cloud_action' = 'Erlauben Sie diesem Rechner, die Adresse Ihrer ToutWAF Cloud \u00fcber Port 443 zu erreichen (nur ausgehend), oder setzen Sie HTTPS_PROXY, falls ein Proxy n\u00f6tig ist. Eingehend muss nichts ge\u00f6ffnet werden.'
        's_db' = 'Datenbank wird vorbereitet'
        'db_choose' = 'Welche Datenbank soll ToutWAF verwenden?'
        'db_opt_pg' = 'PostgreSQL (empfohlen)'
        'db_opt_pg_local' = 'PostgreSQL auf diesem Rechner installieren (wird f\u00fcr Sie eingerichtet)'
        'db_opt_pg_remote' = 'Vorhandenen PostgreSQL-Server verwenden (wird getestet und bei Erlaubnis vorbereitet)'
        'db_opt_sqlite' = 'SQLite (kleine Installation, nur ein Server)'
        'db_sqlite_note' = 'SQLite ist eine Datei auf diesem Rechner: gut f\u00fcr eine kleine Installation auf einem Server. Sie kann nicht von mehreren Control Planes geteilt werden und hat keine Replikation. Sp\u00e4ter k\u00f6nnen Sie zu PostgreSQL wechseln: toutwaf-cp db migrate.'
        'db_q_host' = 'PostgreSQL-Host'
        'db_q_port' = 'Port'
        'db_q_name' = 'Datenbankname'
        'db_q_user' = 'Datenbankbenutzer'
        'db_q_pw' = 'Passwort dieses Benutzers (leer, wenn ein Administratorkonto ihn anlegt)'
        'db_q_tls' = 'TLS-Modus (disable, prefer, require, verify-ca, verify-full)'
        'db_q_ca' = 'CA-Zertifikatsdatei des Servers (f\u00fcr verify-ca / verify-full)'
        'db_q_admin' = 'Administratorkonto, das Benutzer und Datenbank anlegt (leer = existieren bereits)'
        'db_q_adminpw' = 'Passwort des Administratorkontos (einmal verwendet, nie gespeichert)'
        'db_hint' = 'Datenbank: SQLite (Standard). F\u00fcr eine Server-Installation oder mehrere Control Planes verwenden Sie --db postgres (--db-install-local installiert es f\u00fcr Sie).'
        'db_no_pkg' = 'PostgreSQL l\u00e4sst sich auf diesem System nicht automatisch installieren: installieren Sie das Serverpaket selbst und starten Sie den Installer erneut mit --db postgres.'
        'db_install_failed' = 'Die Installation des PostgreSQL-Pakets ist fehlgeschlagen. Das Protokoll nennt den Grund (/var/log/toutwaf-install.log).'
        'db_init_failed' = 'Der PostgreSQL-Cluster konnte nicht initialisiert werden. Das Protokoll nennt den Grund.'
        'db_start_failed' = 'PostgreSQL startet nicht. Pr\u00fcfen Sie: systemctl status postgresql und das Protokoll.'
        'db_too_old' = 'Die hier installierte PostgreSQL-Version ({0}) ist zu alt: Version 13 oder neuer ist erforderlich.'
        'db_exists' = 'Ein Benutzer "{0}" oder eine Datenbank "{1}" existiert bereits und wurde nicht von diesem Installer angelegt: nichts wurde ge\u00e4ndert. W\u00e4hlen Sie andere Namen (--db-name, --db-user) oder geben Sie die vorhandene Verbindung an (--db-dsn-file).'
        'db_create_failed' = 'Benutzer oder Datenbank konnten nicht angelegt werden. Was angelegt wurde, wurde wieder entfernt.'
        'db_rights' = 'Das Konto darf das nicht. Die obigen Anweisungen sind das Minimum, das ein Serveradministrator ausf\u00fchren muss; starten Sie danach den Installer erneut.'
        'db_need_conn' = 'Es wurde keine Verbindung zum PostgreSQL-Server angegeben: verwenden Sie --db-dsn-file, oder --db-host mit --db-password-file, oder --db-install-local.'
        'db_schema_failed' = 'Die Tabellen konnten in der Datenbank nicht angelegt werden. Das Protokoll nennt den Grund.'
        'db_no_pgdump' = 'pg_dump fehlt: die t\u00e4gliche Datenbanksicherung meldet einen Fehler, bis das PostgreSQL-Client-Paket installiert ist.'
        'db_sum_engine' = 'Datenbank: {0}'
        'db_sum_local' = 'PostgreSQL l\u00e4uft auf diesem Rechner (nur Loopback); Datenbank {0}, Benutzer {1} (ohne Administratorrechte)'
        'db_sum_remote' = 'Vorhandener PostgreSQL-Server; Datenbank {0}, Benutzer {1}'
        'db_sum_schema' = 'Schema: {0}'
        'db_sum_secret' = 'Die Verbindung (mit Passwort) liegt in {0} und ist nur f\u00fcr den ToutWAF-Dienst lesbar'
        'db_sum_backup' = 'Jede Nacht l\u00e4uft ein gepr\u00fcftes pg_dump (7 bleiben erhalten); Status in der Konsole, Sant\u00e9'
        'db_sum_nobackup' = 'Keine automatische Datenbanksicherung: planen Sie pg_dump oder nutzen Sie die Sicherung Ihres Datenbankanbieters'
        'db_sum_sqlite' = 'Datenbank: SQLite, eine Datei auf diesem Rechner (kleine Installation). Sp\u00e4ter zu PostgreSQL wechseln: toutwaf-cp db migrate'
        's_extras' = 'Extras: Windows-Agent und Antivirus-Programme'
        's_extras_ok' = 'Extras installiert: {0} Programme in {1}'
        's_extras_sha' = 'Extras gepr\u00fcft: {0} Datei(en), {1} MiB (SHA-256 und Signatur)'
        's_extras_unchecked' = 'Extras unver\u00e4ndert \u00fcbernommen, ohne SHA256SUMS zur Pr\u00fcfung: {0}'
        'w_extras_dl' = 'Die Extras konnten nicht heruntergeladen werden ({0}). ToutWAF l\u00e4uft auch ohne sie, doch diese Konsole bietet weder Windows noch den Virenschutz an, bis sie installiert sind.'
        'w_extras_sum' = 'Die Extras {0} stimmen nicht mit ihrem SHA-256 im signierten SHA256SUMS \u00fcberein: sie wurden NICHT installiert.'
        'w_extras_bad' = 'Die Extras-Datei {0} ist kein g\u00fcltiges Extras-Archiv: sie wurde NICHT installiert.'
        'w_extras_ver' = 'Die Extras geh\u00f6ren zu Version {0}, diese Installation ist {1}: sie wurden NICHT installiert.'
        'w_extras_inc' = 'Die Version listet {0} Teil(e) der Extras, nennt aber {1}: die Ver\u00f6ffentlichung ist besch\u00e4digt, die Extras wurden NICHT installiert.'
        'w_extras_nofile' = 'Die Extras-Datei {0} existiert nicht.'
        'w_extras_none' = 'Diese Version enth\u00e4lt keine Extras: diese Konsole bietet weder Windows noch den Virenschutz an.'
        'w_extras_todo' = 'Extras nicht installiert. Sobald das Netz es erlaubt, als root ausf\u00fchren: {0}'
        'extras_needs_cp' = 'Die Extras geh\u00f6ren zur Control Plane: sie ist auf diesem Rechner nicht installiert.'
        'extras_other_release' = 'Die ver\u00f6ffentlichte Version ({0}) ist nicht die installierte ({1}): die Extras kommen mit ihr. --update ausf\u00fchren.'
        'st_extras_ok' = 'Extras: installiert (Windows-Agent, Antivirus-Programme)'
        'st_extras_none' = 'Extras fehlen: Windows und der Virenschutz werden nicht angeboten. Als root ausf\u00fchren: {0}'
    }
    'it' = @{
        'tagline' = 'Protezione di applicazioni web e API'
        'menu_title' = 'Cosa vuoi fare?'
        'opt_install' = 'Installa (control plane + data plane + console)'
        'opt_install_d' = 'Tutto su questa macchina: console web, archivio delle policy e reverse proxy / WAF.'
        'opt_cp' = 'Installa solo il control plane'
        'opt_cp_d' = 'Console web, API e archivio delle policy. I data plane (nodi) si uniscono dopo.'
        'opt_dp' = 'Installa solo un data plane'
        'opt_dp_d' = 'Nodo reverse proxy / WAF che si unisce a un control plane esistente (chiede URL e token di registrazione).'
        'opt_update' = 'Aggiorna'
        'opt_update_d' = 'Scarica una versione pi\u00f9 recente, la verifica (SHA-256 / sigstore), esegue il backup, conserva configurazione e dati, ripristina in caso di errore.'
        'opt_uninstall' = 'Disinstalla'
        'opt_uninstall_d' = 'Rimuove ToutWAF; scegli se mantenere o eliminare configurazione, dati e log.'
        'opt_status' = 'Stato e controllo di integrit\u00e0'
        'opt_status_d' = 'Versioni installate, servizi, porte in ascolto ed endpoint di salute.'
        'opt_links' = 'Mostra di nuovo i link del pannello'
        'opt_links_d' = 'URL del pannello, link di configurazione monouso e porte da aprire nel firewall.'
        'opt_quit' = 'Esci'
        'choice' = 'La tua scelta'
        'invalid_choice' = 'Scelta non valida.'
        'state_installed' = 'Installato: {0}'
        'state_none' = 'ToutWAF non \u00e8 installato su questa macchina.'
        'cfg_title' = 'Opzioni di installazione (Invio = predefinito)'
        'q_cp_url' = 'URL del control plane (es. https://cp.example.com:9444)'
        'q_token' = 'Token di registrazione (console: Nodi > Aggiungi nodo)'
        'q_cp_ca' = 'File PEM della CA / certificato del control plane (vuoto = archivio di sistema)'
        'q_cp_port' = 'Porta della console'
        'q_http_port' = 'Porta HTTP'
        'q_https_port' = 'Porta HTTPS'
        'q_public_host' = 'Nome host o indirizzo IP pubblico (vuoto = rilevamento automatico)'
        'q_firewall' = 'Aprire automaticamente il firewall (firewalld / ufw)?'
        'q_boot' = 'Avviare i servizi all''avvio?'
        'q_channel' = 'Canale di rilascio (stable / dev)'
        'q_bindir' = 'Directory di installazione'
        'q_confirm' = 'Procedere con l''installazione?'
        'q_purge' = 'Eliminare anche configurazione, dati e log? (No = conservali)'
        'q_confirm_un' = 'Disinstallare davvero ToutWAF?'
        'aborted' = 'Annullato.'
        'root_required' = 'Eseguire come root (sudo bash install.sh).'
        's_prereq' = 'Installazione dei prerequisiti'
        's_fetch' = 'Download di ToutWAF {0} ({1})'
        's_sha' = 'SHA-256 verificato'
        's_sig' = 'Firma cosign verificata'
        'w_nocosign' = 'cosign non installato: firma non verificata (solo checksum)'
        's_user' = 'Creazione dell''account di servizio e delle directory'
        's_bin' = 'Installazione dei binari'
        's_cfg' = 'Scrittura della configurazione (i file esistenti sono mantenuti)'
        's_units' = 'Installazione delle unit systemd e ottimizzazioni di sistema'
        's_selinux' = 'Configurazione di SELinux'
        'q_console_from' = 'Consenti alla console solo questa rete (CIDR, es. 203.0.113.0/24; vuoto = chiunque)'
        'q_console_from_bad' = 'Non \u00e8 un indirizzo n\u00e9 un CIDR (0.0.0.0/0 equivale a vuoto): la porta della console resta aperta a tutti.'
        'fw_console_note' = 'La console (porta {0}) ospita l''accesso amministrativo: aprirla a tutta Internet \u00e8 comodo ma esposto.'
        'fw_console_open' = 'La porta {0} della console \u00e8 aperta a tutti: limitala con --console-from CIDR o nella console (Impostazioni > Firewall)'
        'fw_console_from' = 'La porta {0} della console \u00e8 aperta solo a {1}'
        'fw_none' = 'Nessun firewall attivo (firewalld / ufw / nftables / iptables): nulla filtra il traffico, nessuna porta da aprire'
        'fw_manual' = 'Il firewall {0} non viene modificato dall''installer: esegui tu questi comandi'
        'fw_failed' = 'Impossibile configurare il firewall: {0}'
        'home_fresh' = 'Nuova installazione: tutto sotto {0} (bin, conf, data, logs)'
        'home_legacy' = 'Installazione esistente rilevata: i suoi percorsi restano (bin {0}, conf {1}, data {2}). Nulla viene spostato; usa --home DIR per il nuovo layout.'
        'home_explicit_legacy' = '--home {0} indicato mentre esiste un''installazione in {1}: i suoi dati NON vengono spostati'
        'home_bad' = '--home deve essere un percorso assoluto (lettere, cifre, . _ - + /), non / n\u00e9 sotto /proc /sys /dev: {0}'
        'home_noexec' = '{0} si trova su un mount noexec: i binari non potrebbero girarvi, scegli un altro --home'
        's_fw' = 'Configurazione del firewall'
        's_boot' = 'Preparazione del pannello (account amministratore, percorso sicuro)'
        's_start' = 'Avvio dei servizi'
        's_health' = 'Attesa dei servizi in salute'
        's_backup' = 'Backup di configurazione e dati'
        'w_rollback' = 'La nuova versione non funziona correttamente: ritorno alla precedente'
        'up_to_date' = 'Gi\u00e0 aggiornato ({0})'
        'not_installed' = 'ToutWAF non \u00e8 installato: niente da aggiornare.'
        'st_channel' = 'Canale: {0}'
        'st_latest' = 'Ultima versione disponibile: {0}'
        'st_newer' = 'aggiornamento disponibile: esegui con --update'
        'e_yanked' = 'La versione {0} \u00e8 stata ritirata (yanked) e non va installata. Esegui --update per la versione corrente, o --force per forzare.'
        'e_nover' = 'Sul canale {0} non \u00e8 ancora pubblicata nessuna versione, quindi non c''\u00e8 nulla da installare. ToutWAF non \u00e8 stato installato n\u00e9 modificato. Per installare dal canale {1}, rilancia l''installer con -Channel {2}.'
        'e_installer_old' = 'Questo installer \u00e8 troppo vecchio per questa versione (richiede la versione {0}): scaricalo di nuovo dall''URL del canale.'
        'up_rebuilt' = 'Stessa versione, nuova build: installata {0}, disponibile {1}. Aggiornamento in corso.'
        'st_newbuild' = 'stessa versione, nuova build disponibile: esegui di nuovo con {0}'
        'st_nochannel' = 'Ultima versione disponibile: su questo canale non \u00e8 ancora stato pubblicato nulla'
        'w_mirror' = 'Il mirror pubblico ha servito file che non concordano tra loro ({0}): probabilmente si sta ancora aggiornando dopo una pubblicazione. Rileggo il canale, una sola volta.'
        'e_mismatch' = 'checksum non corrispondente per {0} ({1}): il file scaricato non corrisponde al checksum pubblicato, quindi non \u00e8 stato installato n\u00e9 modificato nulla. Subito dopo una pubblicazione il mirror pubblico pu\u00f2 servire per qualche minuto i file precedenti: attendi cinque minuti e rilancia l''installer. Se si ripete, non installare: la pubblicazione \u00e8 danneggiata.'
        'e_downgrade' = 'L''ultima versione {0} del canale {1} \u00e8 pi\u00f9 vecchia di quella installata {2}: usa --force per il downgrade.'
        's_sigok' = 'firma della release verificata, chiave {0}'
        'w_sigold' = 'la versione {0} \u00e8 stata pubblicata senza firma (le versioni precedenti a 0.2.0-dev.7 non sono firmate): \u00e8 stato verificato solo lo SHA-256, la firma non ha potuto essere controllata'
        'w_sigskip' = 'firma della release NON verificata: openssl.exe non trovato nel PATH (Windows non ha una verifica Ed25519 integrata), \u00e8 stato controllato solo lo SHA-256. Installa OpenSSL 3 ed esegui di nuovo per verificare con la chiave {0}'
        'done' = 'Fatto.'
        'failed' = 'Fallito'
        'log_hint' = 'Log completo: {0}'
        'dry_done' = 'Simulazione: nulla \u00e8 stato modificato.'
        'sum_title' = 'Riepilogo dell''installazione'
        'sum_panel' = 'Link del pannello'
        'sum_tls_note' = 'Solo HTTPS. Il certificato \u00e8 autofirmato finch\u00e9 non installi il tuo: il browser mostrer\u00e0 un avviso.'
        'sum_local' = 'Indirizzi locali'
        'sum_public' = 'Indirizzo pubblico'
        'sum_public_unknown' = 'Impossibile rilevare l''IP pubblico (offline o bloccato). Usa l''IP pubblico o il nome DNS del server al posto degli indirizzi locali, oppure riesegui con --public-host.'
        'sum_admin' = 'Account amministratore'
        'sum_user' = 'Nome utente'
        'sum_password' = 'Password'
        'sum_pw_once' = 'mostrata UNA sola volta - modificabile in Impostazioni > Accesso / Account'
        'sum_pw_unchanged' = 'invariata (mai rigenerata). Reimpostala con: toutwaf-cp admin reset-password --user {0}'
        'sum_setup' = 'Link di configurazione monouso'
        'sum_setup_note' = 'Aprilo per configurare il link del pannello, l''account e la password nell''installer web.'
        'p_dpapi_warn' = 'La porta 9444 (API data plane) NON \u00e8 aperta: consentila solo dai tuoi nodi data plane'
        'p_dpapi_only' = '9444/tcp solo dai tuoi data plane, ad es.:'
        'sum_setup_none' = 'Nessun link di configurazione questa volta (gi\u00e0 emesso, o account gi\u00e0 esistente). Creane uno con: toutwaf-cp setup-link --regenerate'
        'sum_ports' = 'Porte da aprire nel firewall'
        'sum_cmds' = 'Comandi'
        'sum_cloud' = 'Cloud / hosting: apri queste porte anche nel security group / ACL di rete del provider.'
        'sum_file' = 'Riepilogo salvato (solo root): {0}'
        'sum_fallback' = 'Questo control plane non ha ancora il comando ''bootstrap'': apri l''URL della console e segui la pagina di configurazione.'
        'sum_node_hint' = 'Per gestire questo nodo dalla console: Nodi > Aggiungi nodo, poi imposta control_plane.url / enroll_token in {0}.'
        'q_fwmodule' = 'Vuoi che ToutWAF gestisca anche il firewall di questa macchina?'
        'fwmod_n1' = 'Modulo opzionale, spento salvo risposta affermativa. Durante l''installazione non viene applicato nulla: ogni modifica si rivede nella console.'
        's_bkclient' = 'Installazione del client ToutWAF Backup (firma verificata)'
        'bkc_done' = 'Client ToutWAF Backup installato. Poi: console, Backup > Server di backup, per associare un server.'
        'bkc_fail' = 'Il client ToutWAF Backup NON \u00e8 stato installato ({0}). L\u2019installazione prosegue; installalo pi\u00f9 tardi con --with-backup-client.'
        'bkc_nokey' = 'Il client ToutWAF Backup NON \u00e8 stato installato: manca la chiave pubblica della release. Indicala con --backup-client-pubkey (o TOUTWAF_BACKUP_PUBKEY, o il file backup-release.pub nella cartella di configurazione); senza firma verificata non si installa nulla.'
        'bkc_badsig' = 'Il client ToutWAF Backup NON \u00e8 stato installato: la firma della release NON \u00e8 valida. Non \u00e8 stato installato nulla.'
        'tele_on' = 'Telemetria: per impostazione predefinita ToutWAF condivide con lo spazio dell''editore (app.toutwaf.com) gli attacchi bloccati (indirizzo dell''attaccante, paese, tipo di attacco, regola), cifre aggregate e i nomi host dei siti protetti. Mai il contenuto delle richieste n\u00e9 i visitatori legittimi. Disattivabile con un clic nella console (Impostazioni, Privacy e telemetria), oppure installa con --no-telemetry (o TOUTWAF_TELEMETRY=0) per la telemetria zero. Dettagli: docs/confidentialite-telemetrie.md'
        'tele_off' = 'Telemetria: \u00e8 stata richiesta la telemetria zero (--no-telemetry / TOUTWAF_TELEMETRY=0). Non verr\u00e0 inviato nulla allo spazio dell''editore n\u00e9 ricevuto da esso, e la console parte con l''interruttore \u00abTelemetria zero\u00bb attivo. Potrai cambiarlo pi\u00f9 tardi nella console (Impostazioni, Privacy e telemetria).'
        'fwmod_n2' = 'Ogni modifica passa da una prova con conto alla rovescia e torna indietro da sola se non la conservi; una protezione anti-lockout rifiuta ogni regola che taglierebbe SSH o la console.'
        'fwmod_n3' = 'Non \u00e8 la domanda precedente, che apre solo le porte necessarie a ToutWAF nel firewall di sistema (--no-firewall).'
        's_fwmod' = 'Attivazione del modulo firewall (nessuna regola applicata)'
        'fwmod_done' = 'Modulo firewall attivato. Non \u00e8 stato applicato nulla: apri Firewall nella console per rivedere e provare le regole.'
        'fwmod_fail' = 'Impossibile attivare il modulo firewall ({0}). L''installazione prosegue; attivalo pi\u00f9 tardi in Impostazioni > Moduli.'
        's_link' = 'Collegamento del data plane alla console'
        'dp_link_ok' = 'Data plane collegato automaticamente alla console: nulla da configurare a mano.'
        'dp_link_same' = 'Data plane gi\u00e0 collegato alla console; la sua configurazione non \u00e8 stata modificata.'
        'dp_link_fixed' = 'Configurazione del data plane riparata (blocchi control_plane duplicati uniti in uno); il file precedente \u00e8 stato conservato.'
        'dp_link_remote' = 'Il data plane di questa macchina \u00e8 configurato per un''altra console; non \u00e8 stato modificato.'
        'dp_link_fail' = 'Non \u00e8 stato possibile collegare automaticamente il data plane alla console: {0}'
        'dp_link_fail_hint' = 'Il data plane mantiene la configurazione autonoma, quindi i siti rispondono HTTP 421 finch\u00e9 non \u00e8 collegato. Correggi la causa indicata sopra ed esegui di nuovo questo installer: collega il nodo da solo.'
        'st_title' = 'Stato'
        'st_healthy' = 'funzionante'
        'st_unhealthy' = 'NON funzionante'
        'st_active' = 'attivo'
        'st_inactive' = 'inattivo'
        'st_listening' = 'in ascolto'
        'st_closed' = 'non in ascolto'
        'un_title' = 'Disinstallazione di ToutWAF'
        'un_kept' = 'Configurazione mantenuta in {0}, dati in {1} (usa --purge per eliminare).'
        'un_purged' = 'Configurazione, dati e log eliminati.'
        'p_console' = 'console web + API'
        'p_http' = 'HTTP (reverse proxy)'
        'p_https' = 'HTTPS (reverse proxy)'
        'p_dpapi' = 'API dei data plane: SOLO se i data plane sono su ALTRI host (limita ai loro IP)'
        'w_fw_manual' = 'La porta {0}/tcp non \u00e8 stata aperta automaticamente: vedi i comandi nel riepilogo.'
        'need_cp' = 'Serve l''URL di un control plane quando si indica un token di registrazione.'
        'cp_title' = 'Compatibilit\u00e0 del sistema'
        'cp_detected' = 'Rilevato: {0}, arch {1}, glibc {2}, systemd {3}, kernel {4}'
        'cp_ok' = 'Compatibile: {0} ({1})'
        'cp_tested' = 'testato'
        'cp_expected' = 'previsto'
        'cp_w_like' = '{0} non \u00e8 nella tabella di compatibilit\u00e0: trattato come famiglia {1} (previsto). Si continua.'
        'cp_w_newer' = '{0} {1} \u00e8 pi\u00f9 recente delle versioni elencate: non ancora validato (previsto). Si continua.'
        'cp_w_unlisted' = '{0} {1} non \u00e8 elencato nella tabella: trattato come previsto. Si continua.'
        'cp_w_nover' = '{0} non dichiara una versione (rolling o testing): trattato come previsto. Si continua.'
        'cp_w_glibc' = 'Impossibile determinare la versione di glibc; si continua.'
        'cp_w_skip' = '--skip-os-check: il controllo di compatibilit\u00e0 \u00e8 ignorato. Questo sistema NON \u00e8 supportato: si continua a proprio rischio.'
        'cp_w_stage' = 'Staging (--destdir): il verdetto di compatibilit\u00e0 \u00e8 solo informativo, nulla viene rifiutato.'
        'cp_refused' = 'Questo sistema non \u00e8 compatibile con ToutWAF:'
        'cp_r_old' = '{0} {1} \u00e8 pi\u00f9 vecchio della versione minima supportata ({2}).'
        'cp_r_eol' = '{0} {1} \u00e8 a fine vita, oppure la sua glibc / systemd \u00e8 troppo vecchia.'
        'cp_r_glibc' = 'glibc {0} trovata: serve {1} o successiva.'
        'cp_r_musl' = 'musl libc trovata: serve glibc {0} o successiva.'
        'cp_r_init' = '{0} {1} non usa systemd, richiesto da ToutWAF.'
        'cp_r_immutable' = '{0} {1} ha un filesystem root immutabile (non supportato).'
        'cp_r_layout' = '{0} {1} non segue la struttura standard di Linux (non supportato).'
        'cp_r_arch' = 'L''architettura {0} non \u00e8 supportata (supportata: {1}).'
        'cp_r_distro_arch' = '{0} {1} gira su un''architettura senza build di ToutWAF.'
        'cp_r_systemd' = 'systemd non \u00e8 in esecuzione come init (manca /run/systemd/system): \u00e8 necessario per i servizi.'
        'cp_r_systemd_old' = 'systemd {0} trovato: serve {1} o successivo.'
        'cp_r_kernel' = 'Kernel Linux {0} trovato: serve {1} o successivo.'
        'cp_r_unknown' = 'La distribuzione ''{0}'' non \u00e8 riconosciuta e non dichiara alcuna famiglia nota (ID_LIKE=''{1}'').'
        'cp_r_noosr' = 'Manca /etc/os-release: impossibile identificare la distribuzione.'
        'cp_nochange' = 'Nessuna modifica \u00e8 stata apportata a questo sistema.'
        'cp_list' = 'Sistemi compatibili (amd64 e arm64, glibc {0} o successiva, systemd {1} o successivo):'
        'cp_rolling' = 'rolling'
        'cp_any' = 'qualsiasi versione'
        'cp_override' = 'Per installare comunque, a proprio rischio: --skip-os-check. Dettagli: docs/install/platforms.md'
        'cp_not_root' = 'Non eseguito come root: usare sudo per installare (il controllo non lo richiede).'
        'sum_compat' = 'Compatibilit\u00e0'
        'cp_prereq_arch' = 'I database dei pacchetti non sono sincronizzati. Eseguire prima ''pacman -Syu'' (un aggiornamento parziale non \u00e8 supportato su Arch), poi rilanciare l''installer.'
        'cp_wdetected' = 'Rilevato: {0} (build {1}), arch {2}'
        'cp_wlist' = 'Versioni di Windows compatibili (amd64 e arm64; arm64 non testato su hardware reale):'
        'cp_r_arm32' = 'ARM a 32 bit (armv7) non \u00e8 supportato da ToutWAF. Installare un sistema a 64 bit (Raspberry Pi OS 64 bit, Ubuntu o Debian arm64; Raspberry Pi 3, 4, 5 o Zero 2 W) e rilanciare l''installer.'
        'cp_r_arm_userland32' = 'Il kernel \u00e8 a 64 bit ma il sistema (userland) \u00e8 a 32 bit. ToutWAF richiede un sistema a 64 bit: reinstallare con Raspberry Pi OS 64 bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) o Ubuntu / Debian arm64.'
        'cp_w_pi' = 'Raspberry Pi rilevato: arm64 \u00e8 stato provato solo in emulazione, non su hardware reale. Mettere dati e log su un SSD / disco USB invece che sulla scheda SD ed evitare l''installazione tutto-in-uno sotto 2 GB di RAM (vedere docs/install/raspberry-pi.md).'
        'pf_title' = 'Verifica di ci\u00f2 di cui ha bisogno questa macchina'
        'pf_ok' = 'Nulla \u00e8 d''intralcio: le porte di cui ha bisogno ToutWAF sono libere.'
        'pf_refused' = 'ToutWAF non pu\u00f2 essere installato su questa macchina cos\u00ec com''\u00e8. Non \u00e8 stato modificato nulla.'
        'pf_ok_warn' = 'Nulla impedisce l''installazione, ma leggi i punti qui sopra.'
        'pf_l_refuse' = 'rifiutato'
        'pf_l_warn' = 'attenzione'
        'pf_l_info' = 'nota'
        'pf_port_busy' = 'La porta {0} \u00e8 gi\u00e0 usata da {1}.'
        'pf_prog_other' = 'un altro programma'
        'pf_prog_unknown' = 'un altro programma (il suo nome non \u00e8 leggibile)'
        'pf_act_web' = 'ToutWAF ha bisogno delle porte {0} e {1} per proteggere i tuoi siti. Ferma quel programma o spostalo su altre porte (ToutPanel, installato accanto a ToutWAF, mette il suo server web su 8080 e 8443), poi rilancia l''installer.'
        'pf_act_console' = 'La console di ToutWAF ha bisogno di questa porta. Liberala oppure scegli un''altra porta per la console (l''installer la chiede nel suo menu), poi rilancia l''installer.'
        'pf_act_agent' = 'ToutWAF usa questa porta per i data plane e gli agenti che vi si collegano. Liberala, poi rilancia l''installer.'
        'pf_act_admin' = 'Il data plane usa questa porta solo su questa macchina, per il proprio controllo di stato. Liberala, poi rilancia l''installer.'
        'pf_nostart' = '(ora non viene avviato nulla, quindi \u00e8 solo una segnalazione)'
        'pf_boot' = '{0} \u00e8 installato e parte con la macchina, anche se ora \u00e8 fermo. Al prossimo riavvio occuperebbe le porte {1} e {2} prima di ToutWAF.'
        'pf_act_boot' = 'Disattivalo perch\u00e9 non parta con la macchina, oppure spostalo su altre porte, prima del riavvio della macchina.'
        'pf_fw_cause' = 'Un firewall ({0}) \u00e8 attivo e non lascia passare le porte {1} e {2}, e all''installer \u00e8 stato detto di non modificarlo.'
        'pf_fw_action' = 'Apri queste porte nel firewall oppure lascia che lo faccia l''installer (senza l''opzione --no-firewall). Altrimenti i tuoi siti non saranno raggiungibili dall''esterno.'
        'pf_fwx_cause' = 'Il firewall di questa macchina ({0}) rifiuta le connessioni in ingresso per impostazione predefinita e non ha regole per le porte {1} e {2}.'
        'pf_fwx_action' = 'ToutWAF non modifica mai da solo le regole di questo tipo di firewall: apri queste porte nella sua configurazione, poi controlla i tuoi siti.'
        'pf_cp_cause' = 'Il control plane {0} non \u00e8 raggiungibile da questa macchina.'
        'pf_cp_action' = 'Verifica l''indirizzo, che il control plane sia in funzione e che il suo firewall lasci raggiungerlo da questa macchina (porta 9444 per impostazione predefinita), poi rilancia l''installer.'
        'pf_router_cause' = 'Questa macchina ha un indirizzo privato ({0}): probabilmente \u00e8 dietro un router.'
        'pf_router_action' = 'Una volta installato, ToutWAF indica quali porte inoltrare a questa macchina e fornisce i file per i router pi\u00f9 comuni. Non c''\u00e8 nulla da preparare ora.'
        'pf_skipped' = 'La verifica dell''ambiente \u00e8 stata saltata come richiesto: ci\u00f2 che \u00e8 d''intralcio far\u00e0 fallire pi\u00f9 tardi l''installazione o l''avvio.'
        's_sysupdate' = 'Aggiornamento dei pacchetti di sistema (pu\u00f2 richiedere qualche minuto)'
        'su_skipped' = 'I pacchetti di sistema non vengono aggiornati prima (TOUTWAF_SKIP_SYSUPDATE).'
        'su_recent' = 'I pacchetti di sistema sono stati aggiornati meno di 6 ore fa: non si ripete.'
        'su_dry' = 'i pacchetti di sistema verrebbero aggiornati per primi (si salta con TOUTWAF_SKIP_SYSUPDATE=1)'
        'su_nopm' = 'Nessun gestore di pacchetti supportato per aggiornare il sistema: saltato, l''installazione continua.'
        'su_failed' = 'L''aggiornamento dei pacchetti di sistema non \u00e8 riuscito (codice {0}); l''installazione continua senza. Dettagli: {1}. Soluzione: esegui tu l''aggiornamento e leggi l''errore (repository guasto? un altro gestore di pacchetti in esecuzione?), oppure rilancia questo comando con TOUTWAF_SKIP_SYSUPDATE=1.'
        'su_reboot' = 'Serve riavviare questo server per completare l''aggiornamento del sistema (nuovo kernel o librerie). ToutWAF non lo riavvia mai al posto tuo: fallo quando puoi.'
        'q_sysupdate' = 'Aggiornare prima i pacchetti di sistema (consigliato)?'
        'pr_disk_full' = 'Solo {0} MB liberi su {1} (ne servono almeno {2} MB): l''installazione non potrebbe concludersi.'
        'pr_disk_full_a' = 'Libera spazio (cache dei pacchetti: apt-get clean o dnf clean all; vecchi log: journalctl --vacuum-size=100M), poi rilancia questo comando. Per proseguire comunque: TOUTWAF_SKIP_PREREQ=1.'
        'pr_disk_full_w_a' = 'Libera spazio (Pulizia disco, svuota il cestino), poi rilancia questo comando. Per proseguire comunque: $env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = 'Solo {0} MB liberi su {1} (circa {2} MB sono comodi).'
        'pr_disk_low_a' = 'Libera spazio o aggiungi disco; l''installazione pu\u00f2 proseguire.'
        'pr_dns' = 'Questa macchina non riesce a risolvere il nome {0} (DNS).'
        'pr_dns_a' = 'Controlla i server DNS (cat /etc/resolv.conf, resolvectl status), aggiungine uno funzionante, ad esempio nameserver 9.9.9.9, poi rilancia questo comando.'
        'pr_dns_w_a' = 'Controlla i server DNS con ''ipconfig /all'', imposta un server funzionante (ad esempio 9.9.9.9) nelle impostazioni della scheda di rete, poi rilancia questo comando.'
        'pr_clock' = 'L''orologio di questa macchina \u00e8 sfasato di {0} secondi rispetto all''ora di Internet: certificati TLS e firme falliscono se l''orologio \u00e8 sbagliato.'
        'pr_clock_a' = 'Sincronizzalo: timedatectl set-ntp true (o chronyc makestep), verifica con timedatectl, poi rilancia questo comando.'
        'pr_clock_w_a' = 'Sincronizzalo: w32tm /resync (oppure Impostazioni > Ora e lingua > Sincronizza ora), poi rilancia questo comando.'
        'pr_ok' = 'Spazio su disco, DNS e orologio sono a posto.'
        'cloud_https' = '--cloud-url deve essere un indirizzo https:// (il nodo non parla mai con il cloud in chiaro).'
        'cloud_dp_only' = '--cloud-url installa un nodo di protezione: usarlo con --component dp (predefinito in modalit\u00e0 cloud).'
        'cloud_need_token' = 'Serve un token di iscrizione per collegare questo nodo al tuo account (--enroll-token; console: Nodi > Aggiungi il mio primo nodo).'
        'cloud_ca_local' = '--cloud-ca deve essere un file locale.'
        'cloud_nolink' = 'Questa versione non contiene il collegamento ToutWAF Cloud (toutwaf-cloudlink): aggiorna l''installer o usa una versione pi\u00f9 recente.'
        'cloud_enrol_failed' = 'Non \u00e8 stato possibile iscrivere il nodo al tuo account (vedi le righe sopra). Il token potrebbe essere usato o scaduto: creane uno nuovo nella console.'
        'pf_cloud_action' = 'Consenti a questa macchina di raggiungere l''indirizzo del tuo ToutWAF Cloud sulla porta 443 (solo in uscita), oppure imposta HTTPS_PROXY se serve un proxy. Non va aperto nulla in ingresso.'
        's_db' = 'Preparazione del database'
        'db_choose' = 'Quale database deve usare ToutWAF?'
        'db_opt_pg' = 'PostgreSQL (consigliato)'
        'db_opt_pg_local' = 'Installare PostgreSQL su questa macchina (creato e configurato per te)'
        'db_opt_pg_remote' = 'Usare un server PostgreSQL esistente (testato, poi preparato se lo consenti)'
        'db_opt_sqlite' = 'SQLite (piccola installazione, un solo server)'
        'db_sqlite_note' = 'SQLite \u00e8 un file su questa macchina: va bene per una piccola installazione su un solo server. Non pu\u00f2 essere condiviso tra pi\u00f9 piani di controllo e non ha replica. Potrai passare a PostgreSQL pi\u00f9 tardi con: toutwaf-cp db migrate.'
        'db_q_host' = 'Host PostgreSQL'
        'db_q_port' = 'Porta'
        'db_q_name' = 'Nome del database'
        'db_q_user' = 'Utente del database'
        'db_q_pw' = 'Password di quell''utente (vuota se lo crea un account amministratore)'
        'db_q_tls' = 'Modalit\u00e0 TLS (disable, prefer, require, verify-ca, verify-full)'
        'db_q_ca' = 'File del certificato CA del server (per verify-ca / verify-full)'
        'db_q_admin' = 'Account amministratore che crea utente e database (vuoto = esistono gi\u00e0)'
        'db_q_adminpw' = 'Password dell''account amministratore (usata una volta, mai salvata)'
        'db_hint' = 'Database: SQLite (predefinito). Per un''installazione server o pi\u00f9 piani di controllo usa --db postgres (--db-install-local lo installa per te).'
        'db_no_pkg' = 'PostgreSQL non pu\u00f2 essere installato automaticamente su questo sistema: installa tu il pacchetto server, poi riesegui l''installer con --db postgres.'
        'db_install_failed' = 'L''installazione del pacchetto PostgreSQL \u00e8 fallita. Il registro ne indica il motivo (/var/log/toutwaf-install.log).'
        'db_init_failed' = 'Impossibile inizializzare il cluster PostgreSQL. Il registro ne indica il motivo.'
        'db_start_failed' = 'PostgreSQL non si avvia. Controlla: systemctl status postgresql e il registro.'
        'db_too_old' = 'La versione di PostgreSQL installata qui ({0}) \u00e8 troppo vecchia: serve la versione 13 o successiva.'
        'db_exists' = 'Esiste gi\u00e0 un utente "{0}" o un database "{1}" non creato da questo installer: nulla \u00e8 stato modificato. Scegli altri nomi (--db-name, --db-user) o indica la connessione esistente (--db-dsn-file).'
        'db_create_failed' = 'Impossibile creare l''utente o il database. Quanto creato \u00e8 stato rimosso.'
        'db_rights' = 'L''account non ha i permessi necessari. Le istruzioni qui sopra sono il minimo che un amministratore del server deve eseguire; poi riesegui l''installer.'
        'db_need_conn' = 'Nessuna connessione al server PostgreSQL indicata: usa --db-dsn-file, oppure --db-host con --db-password-file, oppure --db-install-local.'
        'db_schema_failed' = 'Impossibile creare le tabelle nel database. Il registro ne indica il motivo.'
        'db_no_pgdump' = 'pg_dump manca: il backup giornaliero del database segnaler\u00e0 un errore finch\u00e9 non sar\u00e0 installato il pacchetto client PostgreSQL.'
        'db_sum_engine' = 'Database: {0}'
        'db_sum_local' = 'PostgreSQL gira su questa macchina (solo loopback); database {0}, utente {1} (senza diritti di amministrazione)'
        'db_sum_remote' = 'Server PostgreSQL esistente; database {0}, utente {1}'
        'db_sum_schema' = 'Schema: {0}'
        'db_sum_secret' = 'La connessione (con la password) \u00e8 in {0}, leggibile solo dal servizio ToutWAF'
        'db_sum_backup' = 'Ogni notte gira un pg_dump verificato (se ne conservano 7); stato nella console, Sant\u00e9'
        'db_sum_nobackup' = 'Nessun backup automatico del database: pianifica pg_dump o usa il backup del tuo fornitore di database'
        'db_sum_sqlite' = 'Database: SQLite, un file su questa macchina (piccola installazione). Passare a PostgreSQL pi\u00f9 tardi: toutwaf-cp db migrate'
        's_extras' = 'Extra: agente Windows e programmi dell''antivirus'
        's_extras_ok' = 'Extra installati: {0} programmi in {1}'
        's_extras_sha' = 'Extra verificati: {0} file, {1} MiB (SHA-256 e firma)'
        's_extras_unchecked' = 'Extra usati cos\u00ec come sono, senza SHA256SUMS per verificarli: {0}'
        'w_extras_dl' = 'Impossibile scaricare gli extra ({0}). ToutWAF funziona senza, ma questa console non proporr\u00e0 Windows n\u00e9 l''antivirus finch\u00e9 non saranno installati.'
        'w_extras_sum' = 'Gli extra {0} non corrispondono al loro SHA-256 nel SHA256SUMS firmato: NON sono stati installati.'
        'w_extras_bad' = 'Il file di extra {0} non \u00e8 un archivio di extra valido: NON \u00e8 stato installato.'
        'w_extras_ver' = 'Gli extra sono della versione {0}, questa installazione \u00e8 {1}: NON sono stati installati.'
        'w_extras_inc' = 'La versione elenca {0} parte/i degli extra ma ne dichiara {1}: la pubblicazione \u00e8 danneggiata, gli extra NON sono stati installati.'
        'w_extras_nofile' = 'Il file di extra {0} non esiste.'
        'w_extras_none' = 'Questa versione non contiene extra: questa console non proporr\u00e0 Windows n\u00e9 l''antivirus.'
        'w_extras_todo' = 'Extra non installati. Quando la rete lo consente, eseguire come root: {0}'
        'extras_needs_cp' = 'Gli extra appartengono al control plane: non \u00e8 installato su questa macchina.'
        'extras_other_release' = 'La versione pubblicata ({0}) non \u00e8 quella installata ({1}): gli extra arrivano con essa. Eseguire --update.'
        'st_extras_ok' = 'Extra: installati (agente Windows, programmi dell''antivirus)'
        'st_extras_none' = 'Extra mancanti: Windows e l''antivirus non sono proposti. Eseguire come root: {0}'
    }
    'pt' = @{
        'tagline' = 'Prote\u00e7\u00e3o de aplica\u00e7\u00f5es web e APIs'
        'menu_title' = 'O que deseja fazer?'
        'opt_install' = 'Instalar (plano de controlo + plano de dados + consola)'
        'opt_install_d' = 'Tudo nesta m\u00e1quina: consola web, reposit\u00f3rio de pol\u00edticas e proxy reverso / WAF.'
        'opt_cp' = 'Instalar apenas o plano de controlo'
        'opt_cp_d' = 'Console web, API e reposit\u00f3rio de pol\u00edticas. Os planos de dados (n\u00f3s) aderem depois.'
        'opt_dp' = 'Instalar apenas um plano de dados'
        'opt_dp_d' = 'N\u00f3 de proxy reverso / WAF que se junta a um plano de controlo existente (pede a URL e um token de inscri\u00e7\u00e3o).'
        'opt_update' = 'Atualizar'
        'opt_update_d' = 'Transfere uma vers\u00e3o mais recente, verifica-a (SHA-256 / sigstore), faz uma c\u00f3pia de seguran\u00e7a, mant\u00e9m configura\u00e7\u00e3o e dados e reverte em caso de falha.'
        'opt_uninstall' = 'Desinstalar'
        'opt_uninstall_d' = 'Remove o ToutWAF; escolhe se mant\u00e9m ou apaga a configura\u00e7\u00e3o, os dados e os logs.'
        'opt_status' = 'Estado e verifica\u00e7\u00e3o de integridade'
        'opt_status_d' = 'Vers\u00f5es instaladas, servi\u00e7os, portas em escuta e endpoints de sa\u00fade.'
        'opt_links' = 'Mostrar novamente as liga\u00e7\u00f5es do painel'
        'opt_links_d' = 'URLs do painel, liga\u00e7\u00e3o de configura\u00e7\u00e3o de utiliza\u00e7\u00e3o \u00fanica e portas a abrir na firewall.'
        'opt_quit' = 'Sair'
        'choice' = 'A sua escolha'
        'invalid_choice' = 'Escolha inv\u00e1lida.'
        'state_installed' = 'Instalado: {0}'
        'state_none' = 'O ToutWAF n\u00e3o est\u00e1 instalado nesta m\u00e1quina.'
        'cfg_title' = 'Op\u00e7\u00f5es de instala\u00e7\u00e3o (Enter = padr\u00e3o)'
        'q_cp_url' = 'URL do plano de controlo (ex. https://cp.example.com:9444)'
        'q_token' = 'Token de inscri\u00e7\u00e3o (consola: N\u00f3s > Adicionar n\u00f3)'
        'q_cp_ca' = 'Ficheiro PEM da CA / certificado do plano de controlo (vazio = reposit\u00f3rio do sistema)'
        'q_cp_port' = 'Porta da consola'
        'q_http_port' = 'Porta HTTP'
        'q_https_port' = 'Porta HTTPS'
        'q_public_host' = 'Nome de host ou IP p\u00fablico (vazio = dete\u00e7\u00e3o autom\u00e1tica)'
        'q_firewall' = 'Abrir a firewall automaticamente (firewalld / ufw)?'
        'q_boot' = 'Iniciar os servi\u00e7os no arranque?'
        'q_channel' = 'Canal de lan\u00e7amento (stable / dev)'
        'q_bindir' = 'Diret\u00f3rio de instala\u00e7\u00e3o'
        'q_confirm' = 'Prosseguir com a instala\u00e7\u00e3o?'
        'q_purge' = 'Apagar tamb\u00e9m configura\u00e7\u00e3o, dados e logs? (N\u00e3o = manter)'
        'q_confirm_un' = 'Desinstalar mesmo o ToutWAF?'
        'aborted' = 'Cancelado.'
        'root_required' = 'Execute como root (sudo bash install.sh).'
        's_prereq' = 'A instalar pr\u00e9-requisitos'
        's_fetch' = 'A transferir o ToutWAF {0} ({1})'
        's_sha' = 'SHA-256 verificado'
        's_sig' = 'Assinatura cosign verificada'
        'w_nocosign' = 'cosign n\u00e3o instalado: assinatura n\u00e3o verificada (apenas checksum)'
        's_user' = 'A criar a conta de servi\u00e7o e os diret\u00f3rios'
        's_bin' = 'A instalar bin\u00e1rios'
        's_cfg' = 'A gravar a configura\u00e7\u00e3o (os ficheiros existentes s\u00e3o mantidos)'
        's_units' = 'A instalar unidades systemd e ajustes do sistema'
        's_selinux' = 'A configurar o SELinux'
        'q_console_from' = 'Permitir apenas esta rede na consola (CIDR, ex. 203.0.113.0/24; vazio = qualquer um)'
        'q_console_from_bad' = 'N\u00e3o \u00e9 um endere\u00e7o nem um CIDR (0.0.0.0/0 equivale a vazio): a porta da consola fica aberta a todos.'
        'fw_console_note' = 'A consola (porta {0}) cont\u00e9m o in\u00edcio de sess\u00e3o de administra\u00e7\u00e3o: abri-la a toda a Internet \u00e9 c\u00f3modo, mas exposto.'
        'fw_console_open' = 'A porta {0} da consola est\u00e1 aberta a todos: restrinja com --console-from CIDR ou na consola (Defini\u00e7\u00f5es > Firewall)'
        'fw_console_from' = 'A porta {0} da consola est\u00e1 aberta apenas a {1}'
        'fw_none' = 'Nenhuma firewall ativa (firewalld / ufw / nftables / iptables): nada filtra o tr\u00e1fego, nenhuma porta a abrir'
        'fw_manual' = 'A firewall {0} n\u00e3o \u00e9 modificada pelo instalador: execute estes comandos por si'
        'fw_failed' = 'N\u00e3o foi poss\u00edvel configurar a firewall: {0}'
        'home_fresh' = 'Nova instala\u00e7\u00e3o: tudo fica em {0} (bin, conf, data, logs)'
        'home_legacy' = 'Instala\u00e7\u00e3o existente detetada: os caminhos s\u00e3o mantidos (bin {0}, conf {1}, data {2}). Nada \u00e9 movido; use --home DIR para o novo layout.'
        'home_explicit_legacy' = '--home {0} foi informado enquanto existe uma instala\u00e7\u00e3o em {1}: os dados dela N\u00c3O s\u00e3o movidos'
        'home_bad' = '--home deve ser um caminho absoluto (letras, d\u00edgitos, . _ - + /), n\u00e3o / nem sob /proc /sys /dev: {0}'
        'home_noexec' = '{0} est\u00e1 numa montagem noexec: os bin\u00e1rios n\u00e3o poderiam executar ali, escolha outro --home'
        's_fw' = 'A configurar a firewall'
        's_boot' = 'A preparar o painel (conta de administrador, caminho seguro)'
        's_start' = 'A iniciar os servi\u00e7os'
        's_health' = 'A aguardar que os servi\u00e7os fiquem saud\u00e1veis'
        's_backup' = 'C\u00f3pia de seguran\u00e7a de configura\u00e7\u00e3o e dados'
        'w_rollback' = 'A nova vers\u00e3o n\u00e3o est\u00e1 saud\u00e1vel: a voltar \u00e0 anterior'
        'up_to_date' = 'J\u00e1 est\u00e1 atualizado ({0})'
        'not_installed' = 'O ToutWAF n\u00e3o est\u00e1 instalado: nada a atualizar.'
        'st_channel' = 'Canal: {0}'
        'st_latest' = '\u00daltima vers\u00e3o dispon\u00edvel: {0}'
        'st_newer' = 'atualiza\u00e7\u00e3o dispon\u00edvel: execute com --update'
        'e_yanked' = 'A vers\u00e3o {0} foi retirada (yanked) e n\u00e3o deve ser instalada. Execute --update para a vers\u00e3o atual, ou --force para ignorar.'
        'e_nover' = 'Ainda n\u00e3o h\u00e1 nenhuma vers\u00e3o publicada no canal {0}, por isso n\u00e3o h\u00e1 nada para instalar. O ToutWAF n\u00e3o foi instalado nem alterado. Para instalar a partir do canal {1}, execute o instalador de novo com -Channel {2}.'
        'e_installer_old' = 'Este instalador \u00e9 demasiado antigo para esta vers\u00e3o (requer a vers\u00e3o {0}): transfira-o novamente a partir do URL do canal.'
        'up_rebuilt' = 'Mesma vers\u00e3o, nova compila\u00e7\u00e3o: instalada {0}, dispon\u00edvel {1}. A atualizar.'
        'st_newbuild' = 'mesma vers\u00e3o, nova compila\u00e7\u00e3o dispon\u00edvel: execute novamente com {0}'
        'st_nochannel' = '\u00daltima vers\u00e3o dispon\u00edvel: ainda n\u00e3o h\u00e1 nada publicado neste canal'
        'w_mirror' = 'O espelho p\u00fablico serviu ficheiros que n\u00e3o concordam entre si ({0}): provavelmente ainda est\u00e1 a atualizar ap\u00f3s uma publica\u00e7\u00e3o. A ler o canal de novo, uma \u00fanica vez.'
        'e_mismatch' = 'soma de verifica\u00e7\u00e3o incorreta para {0} ({1}): o ficheiro transferido n\u00e3o corresponde \u00e0 soma publicada, por isso nada foi instalado nem alterado. Logo ap\u00f3s uma publica\u00e7\u00e3o, o espelho p\u00fablico pode servir os ficheiros anteriores durante alguns minutos: aguarde cinco minutos e execute o instalador de novo. Se se repetir, n\u00e3o instale: a publica\u00e7\u00e3o est\u00e1 danificada.'
        'e_downgrade' = 'A \u00faltima vers\u00e3o {0} do canal {1} \u00e9 mais antiga do que a instalada {2}: use --force para reverter.'
        's_sigok' = 'assinatura da vers\u00e3o verificada, chave {0}'
        'w_sigold' = 'a vers\u00e3o {0} foi publicada sem assinatura (as anteriores a 0.2.0-dev.7 n\u00e3o s\u00e3o assinadas): s\u00f3 o SHA-256 foi verificado, a assinatura n\u00e3o p\u00f4de ser conferida'
        'w_sigskip' = 'assinatura da vers\u00e3o N\u00c3O verificada: openssl.exe n\u00e3o foi encontrado no PATH (o Windows n\u00e3o tem verifica\u00e7\u00e3o Ed25519 integrada), s\u00f3 o SHA-256 foi conferido. Instale o OpenSSL 3 e execute de novo para verificar com a chave {0}'
        'done' = 'Conclu\u00eddo.'
        'failed' = 'Falhou'
        'log_hint' = 'Registo completo: {0}'
        'dry_done' = 'Simula\u00e7\u00e3o: nada foi alterado.'
        'sum_title' = 'Resumo da instala\u00e7\u00e3o'
        'sum_panel' = 'Liga\u00e7\u00f5es do painel'
        'sum_tls_note' = 'Apenas HTTPS. O certificado \u00e9 autoassinado at\u00e9 instalar o seu: o navegador mostrar\u00e1 um aviso.'
        'sum_local' = 'Endere\u00e7os locais'
        'sum_public' = 'Endere\u00e7o p\u00fablico'
        'sum_public_unknown' = 'N\u00e3o foi poss\u00edvel detetar o IP p\u00fablico (offline ou bloqueado). Use o IP p\u00fablico ou o nome DNS do servidor no lugar dos endere\u00e7os locais, ou execute de novo com --public-host.'
        'sum_admin' = 'Conta de administrador'
        'sum_user' = 'Utilizador'
        'sum_password' = 'Palavra-passe'
        'sum_pw_once' = 'mostrada apenas UMA vez - altere em Defini\u00e7\u00f5es > Acesso / Conta'
        'sum_pw_unchanged' = 'inalterada (nunca regenerada). Reponha com: toutwaf-cp admin reset-password --user {0}'
        'sum_setup' = 'Liga\u00e7\u00e3o de configura\u00e7\u00e3o de utiliza\u00e7\u00e3o \u00fanica'
        'sum_setup_note' = 'Abra-a para configurar a liga\u00e7\u00e3o do painel, a conta e a palavra-passe no assistente web.'
        'p_dpapi_warn' = 'A porta 9444 (API do data plane) N\u00c3O est\u00e1 aberta: permita-a apenas a partir dos seus n\u00f3s data plane'
        'p_dpapi_only' = '9444/tcp apenas a partir dos seus data planes, ex.:'
        'sum_setup_none' = 'Sem liga\u00e7\u00e3o de configura\u00e7\u00e3o desta vez (j\u00e1 emitida, ou a conta j\u00e1 existia). Crie uma com: toutwaf-cp setup-link --regenerate'
        'sum_ports' = 'Portas a abrir na firewall'
        'sum_cmds' = 'Comandos'
        'sum_cloud' = 'Cloud / alojamento: abra tamb\u00e9m estas portas no grupo de seguran\u00e7a / ACL de rede do fornecedor.'
        'sum_file' = 'Resumo guardado (apenas root): {0}'
        'sum_fallback' = 'Este plano de controlo ainda n\u00e3o tem o comando ''bootstrap'': abra a URL da consola e siga a p\u00e1gina de configura\u00e7\u00e3o.'
        'sum_node_hint' = 'Para gerir este n\u00f3 a partir da consola: N\u00f3s > Adicionar n\u00f3 e defina control_plane.url / enroll_token em {0}.'
        'q_fwmodule' = 'Quer que o ToutWAF tamb\u00e9m fa\u00e7a a gest\u00e3o da firewall desta m\u00e1quina?'
        'fwmod_n1' = 'M\u00f3dulo opcional, desligado a n\u00e3o ser que diga que sim. Nada \u00e9 aplicado durante a instala\u00e7\u00e3o: rev\u00ea cada altera\u00e7\u00e3o na consola.'
        's_bkclient' = 'A instalar o cliente ToutWAF Backup (assinatura verificada)'
        'bkc_done' = 'Cliente ToutWAF Backup instalado. Seguinte: consola, C\u00f3pias > Servidores de c\u00f3pia, para associar um servidor.'
        'bkc_fail' = 'O cliente ToutWAF Backup N\u00c3O foi instalado ({0}). A instala\u00e7\u00e3o continua; instale-o depois com --with-backup-client.'
        'bkc_nokey' = 'O cliente ToutWAF Backup N\u00c3O foi instalado: falta a chave p\u00fablica da vers\u00e3o. Indique-a com --backup-client-pubkey (ou TOUTWAF_BACKUP_PUBKEY, ou o ficheiro backup-release.pub na pasta de configura\u00e7\u00e3o); nada \u00e9 instalado sem assinatura verificada.'
        'bkc_badsig' = 'O cliente ToutWAF Backup N\u00c3O foi instalado: a assinatura da vers\u00e3o N\u00c3O \u00e9 v\u00e1lida. Nada foi instalado.'
        'tele_on' = 'Telemetria: por predefini\u00e7\u00e3o, o ToutWAF partilha com o espa\u00e7o do editor (app.toutwaf.com) os ataques que bloqueou (endere\u00e7o do atacante, pa\u00eds, tipo de ataque, regra), n\u00fameros agregados e os nomes de anfitri\u00e3o dos sites protegidos. Nunca o conte\u00fado dos pedidos nem os visitantes leg\u00edtimos. Desativ\u00e1vel com um clique na consola (Defini\u00e7\u00f5es, Privacidade e telemetria), ou instale com --no-telemetry (ou TOUTWAF_TELEMETRY=0) para telemetria zero. Detalhes: docs/confidentialite-telemetrie.md'
        'tele_off' = 'Telemetria: foi pedida a telemetria zero (--no-telemetry / TOUTWAF_TELEMETRY=0). Nada ser\u00e1 enviado ao espa\u00e7o do editor nem recebido dele, e a consola arranca com o interruptor \u00abTelemetria zero\u00bb ativo. Poder\u00e1 alter\u00e1-lo mais tarde na consola (Defini\u00e7\u00f5es, Privacidade e telemetria).'
        'fwmod_n2' = 'Cada altera\u00e7\u00e3o passa por um ensaio com contagem decrescente e volta atr\u00e1s sozinha se n\u00e3o a mantiver; uma prote\u00e7\u00e3o anti-bloqueio recusa qualquer regra que cortaria o SSH ou a consola.'
        'fwmod_n3' = 'N\u00e3o \u00e9 a pergunta anterior, que apenas abre as portas de que o ToutWAF precisa na firewall do sistema (--no-firewall).'
        's_fwmod' = 'A ativar o m\u00f3dulo de firewall (nenhuma regra aplicada)'
        'fwmod_done' = 'M\u00f3dulo de firewall ativado. Nada foi aplicado: abra Firewall na consola para rever e testar regras.'
        'fwmod_fail' = 'N\u00e3o foi poss\u00edvel ativar o m\u00f3dulo de firewall ({0}). A instala\u00e7\u00e3o continua; ative-o depois em Defini\u00e7\u00f5es > M\u00f3dulos.'
        's_link' = 'A ligar o plano de dados \u00e0 consola'
        'dp_link_ok' = 'Plano de dados ligado automaticamente \u00e0 consola: nada a configurar \u00e0 m\u00e3o.'
        'dp_link_same' = 'O plano de dados j\u00e1 est\u00e1 ligado \u00e0 consola; a configura\u00e7\u00e3o n\u00e3o foi alterada.'
        'dp_link_fixed' = 'Configura\u00e7\u00e3o do plano de dados reparada (blocos control_plane duplicados fundidos num s\u00f3); o ficheiro anterior foi mantido.'
        'dp_link_remote' = 'O plano de dados desta m\u00e1quina est\u00e1 configurado para outra consola; n\u00e3o foi alterado.'
        'dp_link_fail' = 'N\u00e3o foi poss\u00edvel ligar automaticamente o plano de dados \u00e0 consola: {0}'
        'dp_link_fail_hint' = 'O plano de dados mant\u00e9m a configura\u00e7\u00e3o aut\u00f3noma, por isso os sites respondem HTTP 421 at\u00e9 ser ligado. Corrija a causa acima e execute novamente este instalador: liga o n\u00f3 sozinho.'
        'st_title' = 'Estado'
        'st_healthy' = 'saud\u00e1vel'
        'st_unhealthy' = 'N\u00c3O saud\u00e1vel'
        'st_active' = 'ativo'
        'st_inactive' = 'inativo'
        'st_listening' = 'a escutar'
        'st_closed' = 'n\u00e3o escuta'
        'un_title' = 'A desinstalar o ToutWAF'
        'un_kept' = 'Configura\u00e7\u00e3o mantida em {0}, dados em {1} (use --purge para apagar).'
        'un_purged' = 'Configura\u00e7\u00e3o, dados e logs apagados.'
        'p_console' = 'consola web + API'
        'p_http' = 'HTTP (proxy reverso)'
        'p_https' = 'HTTPS (proxy reverso)'
        'p_dpapi' = 'API dos planos de dados: APENAS se houver planos de dados noutros hosts (limite aos seus IPs)'
        'w_fw_manual' = 'A porta {0}/tcp n\u00e3o foi aberta automaticamente: veja os comandos no resumo.'
        'need_cp' = '\u00c9 necess\u00e1ria a URL de um plano de controlo quando se indica um token de inscri\u00e7\u00e3o.'
        'cp_title' = 'Compatibilidade do sistema'
        'cp_detected' = 'Detetado: {0}, arq. {1}, glibc {2}, systemd {3}, kernel {4}'
        'cp_ok' = 'Compat\u00edvel: {0} ({1})'
        'cp_tested' = 'testado'
        'cp_expected' = 'esperado'
        'cp_w_like' = '{0} n\u00e3o consta da tabela de compatibilidade: tratado como a fam\u00edlia {1} (esperado). A continuar.'
        'cp_w_newer' = '{0} {1} \u00e9 mais recente do que as vers\u00f5es listadas: ainda n\u00e3o validado (esperado). A continuar.'
        'cp_w_unlisted' = '{0} {1} n\u00e3o consta da tabela: tratado como esperado. A continuar.'
        'cp_w_nover' = '{0} n\u00e3o declara vers\u00e3o (rolling ou testing): tratado como esperado. A continuar.'
        'cp_w_glibc' = 'N\u00e3o foi poss\u00edvel determinar a vers\u00e3o da glibc; continuando.'
        'cp_w_skip' = '--skip-os-check: a verifica\u00e7\u00e3o de compatibilidade foi ignorada. Este sistema N\u00c3O \u00e9 suportado: a continuar por sua conta e risco.'
        'cp_w_stage' = 'Staging (--destdir): o veredito de compatibilidade \u00e9 apenas informativo, nada \u00e9 recusado.'
        'cp_refused' = 'Este sistema n\u00e3o \u00e9 compat\u00edvel com o ToutWAF:'
        'cp_r_old' = '{0} {1} \u00e9 mais antigo do que a vers\u00e3o m\u00ednima suportada ({2}).'
        'cp_r_eol' = '{0} {1} chegou ao fim de vida, ou a sua glibc / systemd \u00e9 demasiado antiga.'
        'cp_r_glibc' = 'glibc {0} encontrada: \u00e9 necess\u00e1ria a {1} ou posterior.'
        'cp_r_musl' = 'musl libc encontrada: \u00e9 necess\u00e1ria a glibc {0} ou posterior.'
        'cp_r_init' = '{0} {1} n\u00e3o usa systemd, exigido pelo ToutWAF.'
        'cp_r_immutable' = '{0} {1} tem um sistema de ficheiros raiz imut\u00e1vel (n\u00e3o suportado).'
        'cp_r_layout' = '{0} {1} n\u00e3o segue a estrutura padr\u00e3o do Linux (n\u00e3o suportado).'
        'cp_r_arch' = 'A arquitetura {0} n\u00e3o \u00e9 suportada (suportada: {1}).'
        'cp_r_distro_arch' = '{0} {1} corre numa arquitetura sem build do ToutWAF.'
        'cp_r_systemd' = 'o systemd n\u00e3o est\u00e1 em execu\u00e7\u00e3o como init (falta /run/systemd/system): \u00e9 necess\u00e1rio para os servi\u00e7os.'
        'cp_r_systemd_old' = 'systemd {0} encontrado: \u00e9 necess\u00e1rio {1} ou posterior.'
        'cp_r_kernel' = 'Kernel Linux {0} encontrado: \u00e9 necess\u00e1rio {1} ou posterior.'
        'cp_r_unknown' = 'A distribui\u00e7\u00e3o ''{0}'' n\u00e3o \u00e9 reconhecida e n\u00e3o declara nenhuma fam\u00edlia conhecida (ID_LIKE=''{1}'').'
        'cp_r_noosr' = 'Falta /etc/os-release: n\u00e3o \u00e9 poss\u00edvel identificar a distribui\u00e7\u00e3o.'
        'cp_nochange' = 'Nada foi alterado neste sistema.'
        'cp_list' = 'Sistemas compat\u00edveis (amd64 e arm64, glibc {0} ou posterior, systemd {1} ou posterior):'
        'cp_rolling' = 'rolling'
        'cp_any' = 'qualquer vers\u00e3o'
        'cp_override' = 'Para instalar mesmo assim, por sua conta e risco: --skip-os-check. Detalhes: docs/install/platforms.md'
        'cp_not_root' = 'N\u00e3o executado como root: use sudo para instalar (a verifica\u00e7\u00e3o n\u00e3o precisa).'
        'sum_compat' = 'Compatibilidade'
        'cp_prereq_arch' = 'As bases de dados de pacotes n\u00e3o est\u00e3o sincronizadas. Execute primeiro ''pacman -Syu'' (uma atualiza\u00e7\u00e3o parcial n\u00e3o \u00e9 suportada no Arch) e volte a executar o instalador.'
        'cp_wdetected' = 'Detetado: {0} (build {1}), arq. {2}'
        'cp_wlist' = 'Vers\u00f5es do Windows compat\u00edveis (amd64 e arm64; arm64 n\u00e3o testado em hardware real):'
        'cp_r_arm32' = 'ARM de 32 bits (armv7) n\u00e3o \u00e9 suportado pelo ToutWAF. Instale um sistema de 64 bits (Raspberry Pi OS 64 bits, Ubuntu ou Debian arm64; Raspberry Pi 3, 4, 5 ou Zero 2 W) e execute o instalador novamente.'
        'cp_r_arm_userland32' = 'O kernel \u00e9 de 64 bits mas o sistema (userland) \u00e9 de 32 bits. O ToutWAF precisa de um sistema de 64 bits: reinstale com Raspberry Pi OS 64 bits (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) ou Ubuntu / Debian arm64.'
        'cp_w_pi' = 'Raspberry Pi detetado: o arm64 s\u00f3 foi testado em emula\u00e7\u00e3o, n\u00e3o em hardware real. Coloque dados e registos num SSD / disco USB em vez do cart\u00e3o SD e evite a instala\u00e7\u00e3o tudo-em-um com menos de 2 GB de RAM (ver docs/install/raspberry-pi.md).'
        'pf_title' = 'A verificar o que esta m\u00e1quina precisa'
        'pf_ok' = 'Nada est\u00e1 no caminho: as portas de que o ToutWAF precisa est\u00e3o livres.'
        'pf_refused' = 'O ToutWAF n\u00e3o pode ser instalado nesta m\u00e1quina como est\u00e1. Nada foi alterado.'
        'pf_ok_warn' = 'Nada impede a instala\u00e7\u00e3o, mas leia os pontos acima.'
        'pf_l_refuse' = 'recusado'
        'pf_l_warn' = 'aten\u00e7\u00e3o'
        'pf_l_info' = 'nota'
        'pf_port_busy' = 'A porta {0} j\u00e1 \u00e9 usada por {1}.'
        'pf_prog_other' = 'outro programa'
        'pf_prog_unknown' = 'outro programa (n\u00e3o foi poss\u00edvel ler o nome)'
        'pf_act_web' = 'O ToutWAF precisa das portas {0} e {1} para proteger os seus sites. Pare esse programa ou mova-o para outras portas (o ToutPanel, instalado ao lado do ToutWAF, coloca o seu servidor web em 8080 e 8443) e volte a executar o instalador.'
        'pf_act_console' = 'A consola do ToutWAF precisa desta porta. Liberte-a ou escolha outra porta para a consola (o instalador pergunta no seu menu) e volte a executar o instalador.'
        'pf_act_agent' = 'O ToutWAF usa esta porta para os planos de dados e os agentes que se ligam a ele. Liberte-a e volte a executar o instalador.'
        'pf_act_admin' = 'O plano de dados usa esta porta apenas nesta m\u00e1quina, para a sua pr\u00f3pria verifica\u00e7\u00e3o de estado. Liberte-a e volte a executar o instalador.'
        'pf_nostart' = '(nada \u00e9 iniciado agora, por isso \u00e9 apenas assinalado)'
        'pf_boot' = '{0} est\u00e1 instalado e arranca com a m\u00e1quina, embora esteja parado neste momento. No pr\u00f3ximo rein\u00edcio ocuparia as portas {1} e {2} antes do ToutWAF.'
        'pf_act_boot' = 'Desative-o para que n\u00e3o arranque com a m\u00e1quina, ou mova-o para outras portas, antes de reiniciar a m\u00e1quina.'
        'pf_fw_cause' = 'Uma firewall ({0}) est\u00e1 ativa e n\u00e3o deixa passar as portas {1} e {2}, e o instalador foi instru\u00eddo a n\u00e3o a alterar.'
        'pf_fw_action' = 'Abra essas portas na firewall ou deixe o instalador faz\u00ea-lo (sem a op\u00e7\u00e3o --no-firewall). Caso contr\u00e1rio, os seus sites n\u00e3o ser\u00e3o acess\u00edveis do exterior.'
        'pf_fwx_cause' = 'A firewall desta m\u00e1quina ({0}) recusa por defeito as liga\u00e7\u00f5es de entrada e n\u00e3o tem nenhuma regra para as portas {1} e {2}.'
        'pf_fwx_action' = 'O ToutWAF nunca altera por si as regras deste tipo de firewall: abra essas portas na sua configura\u00e7\u00e3o e verifique os seus sites.'
        'pf_cp_cause' = 'O plano de controlo {0} n\u00e3o \u00e9 acess\u00edvel a partir desta m\u00e1quina.'
        'pf_cp_action' = 'Verifique o endere\u00e7o, se o plano de controlo est\u00e1 a funcionar e se a sua firewall deixa esta m\u00e1quina chegar a ele (porta 9444 por defeito) e volte a executar o instalador.'
        'pf_router_cause' = 'Esta m\u00e1quina tem um endere\u00e7o privado ({0}): provavelmente est\u00e1 atr\u00e1s de um router.'
        'pf_router_action' = 'Depois de instalado, o ToutWAF indica que portas reencaminhar para esta m\u00e1quina e fornece os ficheiros para os routers habituais. N\u00e3o h\u00e1 nada a preparar agora.'
        'pf_skipped' = 'A verifica\u00e7\u00e3o do ambiente foi ignorada a seu pedido: o que estiver no caminho far\u00e1 falhar mais tarde a instala\u00e7\u00e3o ou o arranque.'
        's_sysupdate' = 'A atualizar os pacotes do sistema (pode demorar alguns minutos)'
        'su_skipped' = 'Os pacotes do sistema n\u00e3o s\u00e3o atualizados antes (TOUTWAF_SKIP_SYSUPDATE).'
        'su_recent' = 'Os pacotes do sistema foram atualizados h\u00e1 menos de 6 horas: n\u00e3o se repete.'
        'su_dry' = 'os pacotes do sistema seriam atualizados primeiro (para saltar: TOUTWAF_SKIP_SYSUPDATE=1)'
        'su_nopm' = 'Nenhum gestor de pacotes suportado para atualizar o sistema: ignorado, a instala\u00e7\u00e3o continua.'
        'su_failed' = 'A atualiza\u00e7\u00e3o dos pacotes do sistema falhou (c\u00f3digo {0}); a instala\u00e7\u00e3o continua sem ela. Detalhes: {1}. Solu\u00e7\u00e3o: execute a atualiza\u00e7\u00e3o e leia o erro (reposit\u00f3rio danificado? outro gestor de pacotes em execu\u00e7\u00e3o?), ou volte a executar este comando com TOUTWAF_SKIP_SYSUPDATE=1.'
        'su_reboot' = '\u00c9 preciso reiniciar este servidor para concluir a atualiza\u00e7\u00e3o do sistema (novo kernel ou bibliotecas). O ToutWAF nunca o reinicia por si: fa\u00e7a-o quando puder.'
        'q_sysupdate' = 'Atualizar primeiro os pacotes do sistema (recomendado)?'
        'pr_disk_full' = 'Apenas {0} MB livres em {1} (s\u00e3o precisos pelo menos {2} MB): a instala\u00e7\u00e3o n\u00e3o poderia terminar.'
        'pr_disk_full_a' = 'Liberte espa\u00e7o (cache de pacotes: apt-get clean ou dnf clean all; registos antigos: journalctl --vacuum-size=100M) e volte a executar este comando. Para continuar mesmo assim: TOUTWAF_SKIP_PREREQ=1.'
        'pr_disk_full_w_a' = 'Liberte espa\u00e7o (Limpeza do Disco, esvaziar a reciclagem) e volte a executar este comando. Para continuar mesmo assim: $env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = 'Apenas {0} MB livres em {1} (cerca de {2} MB s\u00e3o confort\u00e1veis).'
        'pr_disk_low_a' = 'Liberte espa\u00e7o ou adicione disco; a instala\u00e7\u00e3o pode continuar.'
        'pr_dns' = 'Esta m\u00e1quina n\u00e3o consegue resolver o nome {0} (DNS).'
        'pr_dns_a' = 'Verifique os servidores DNS (cat /etc/resolv.conf, resolvectl status), adicione um que funcione, por exemplo nameserver 9.9.9.9, e volte a executar este comando.'
        'pr_dns_w_a' = 'Verifique os servidores DNS com ''ipconfig /all'', defina um que funcione (por exemplo 9.9.9.9) nas defini\u00e7\u00f5es do adaptador de rede e volte a executar este comando.'
        'pr_clock' = 'O rel\u00f3gio desta m\u00e1quina est\u00e1 desfasado {0} segundos em rela\u00e7\u00e3o \u00e0 hora da Internet: os certificados TLS e as assinaturas falham quando o rel\u00f3gio est\u00e1 errado.'
        'pr_clock_a' = 'Sincronize-o: timedatectl set-ntp true (ou chronyc makestep), verifique com timedatectl e volte a executar este comando.'
        'pr_clock_w_a' = 'Sincronize-o: w32tm /resync (ou Defini\u00e7\u00f5es > Hora e idioma > Sincronizar agora) e volte a executar este comando.'
        'pr_ok' = 'O espa\u00e7o em disco, o DNS e o rel\u00f3gio est\u00e3o em ordem.'
        'cloud_https' = '--cloud-url tem de ser um endere\u00e7o https:// (o n\u00f3 nunca fala com a nuvem em claro).'
        'cloud_dp_only' = '--cloud-url instala um n\u00f3 de prote\u00e7\u00e3o: use-o com --component dp (o predefinido no modo nuvem).'
        'cloud_need_token' = '\u00c9 necess\u00e1rio um token de registo para ligar este n\u00f3 \u00e0 sua conta (--enroll-token; consola: N\u00f3s > Adicionar o meu primeiro n\u00f3).'
        'cloud_ca_local' = '--cloud-ca tem de ser um ficheiro local.'
        'cloud_nolink' = 'Esta vers\u00e3o n\u00e3o cont\u00e9m a liga\u00e7\u00e3o ToutWAF Cloud (toutwaf-cloudlink): atualize o instalador ou use uma vers\u00e3o mais recente.'
        'cloud_enrol_failed' = 'N\u00e3o foi poss\u00edvel registar o n\u00f3 na sua conta (veja as linhas acima). O token pode estar usado ou expirado: crie um novo na consola.'
        'pf_cloud_action' = 'Permita que esta m\u00e1quina alcance o endere\u00e7o do seu ToutWAF Cloud na porta 443 (apenas sa\u00edda), ou defina HTTPS_PROXY se for necess\u00e1rio um proxy. Nada precisa de ser aberto \u00e0 entrada.'
        's_db' = 'A preparar a base de dados'
        'db_choose' = 'Que base de dados o ToutWAF deve usar?'
        'db_opt_pg' = 'PostgreSQL (recomendado)'
        'db_opt_pg_local' = 'Instalar o PostgreSQL nesta m\u00e1quina (criado e configurado por si)'
        'db_opt_pg_remote' = 'Usar um servidor PostgreSQL existente (testado e preparado, se permitir)'
        'db_opt_sqlite' = 'SQLite (instala\u00e7\u00e3o pequena, um s\u00f3 servidor)'
        'db_sqlite_note' = 'O SQLite \u00e9 um ficheiro nesta m\u00e1quina: adequado a uma instala\u00e7\u00e3o pequena num s\u00f3 servidor. N\u00e3o pode ser partilhado por v\u00e1rios planos de controlo e n\u00e3o tem replica\u00e7\u00e3o. Poder\u00e1 passar para PostgreSQL mais tarde com: toutwaf-cp db migrate.'
        'db_q_host' = 'Anfitri\u00e3o PostgreSQL'
        'db_q_port' = 'Porta'
        'db_q_name' = 'Nome da base de dados'
        'db_q_user' = 'Utilizador da base de dados'
        'db_q_pw' = 'Palavra-passe desse utilizador (vazia se uma conta de administrador o criar)'
        'db_q_tls' = 'Modo TLS (disable, prefer, require, verify-ca, verify-full)'
        'db_q_ca' = 'Ficheiro do certificado da CA do servidor (para verify-ca / verify-full)'
        'db_q_admin' = 'Conta de administrador que cria o utilizador e a base (vazio = j\u00e1 existem)'
        'db_q_adminpw' = 'Palavra-passe da conta de administrador (usada uma vez, nunca guardada)'
        'db_hint' = 'Base de dados: SQLite (predefini\u00e7\u00e3o). Para um servidor ou v\u00e1rios planos de controlo use --db postgres (--db-install-local instala-o por si).'
        'db_no_pkg' = 'O PostgreSQL n\u00e3o pode ser instalado automaticamente neste sistema: instale o pacote do servidor e volte a executar o instalador com --db postgres.'
        'db_install_failed' = 'A instala\u00e7\u00e3o do pacote PostgreSQL falhou. O registo diz porqu\u00ea (/var/log/toutwaf-install.log).'
        'db_init_failed' = 'N\u00e3o foi poss\u00edvel inicializar o cluster PostgreSQL. O registo diz porqu\u00ea.'
        'db_start_failed' = 'O PostgreSQL n\u00e3o arranca. Verifique: systemctl status postgresql e o registo.'
        'db_too_old' = 'A vers\u00e3o do PostgreSQL instalada aqui ({0}) \u00e9 demasiado antiga: \u00e9 necess\u00e1ria a vers\u00e3o 13 ou posterior.'
        'db_exists' = 'J\u00e1 existe um utilizador "{0}" ou uma base "{1}" que n\u00e3o foi criado por este instalador: nada foi alterado. Escolha outros nomes (--db-name, --db-user) ou indique a liga\u00e7\u00e3o existente (--db-dsn-file).'
        'db_create_failed' = 'N\u00e3o foi poss\u00edvel criar o utilizador ou a base de dados. O que foi criado foi removido.'
        'db_rights' = 'A conta n\u00e3o tem permiss\u00e3o para isto. As instru\u00e7\u00f5es acima s\u00e3o o m\u00ednimo que um administrador do servidor tem de executar; depois volte a executar o instalador.'
        'db_need_conn' = 'N\u00e3o foi indicada nenhuma liga\u00e7\u00e3o ao servidor PostgreSQL: use --db-dsn-file, ou --db-host com --db-password-file, ou --db-install-local.'
        'db_schema_failed' = 'N\u00e3o foi poss\u00edvel criar as tabelas na base de dados. O registo diz porqu\u00ea.'
        'db_no_pgdump' = 'Falta o pg_dump: a c\u00f3pia di\u00e1ria da base de dados dar\u00e1 erro at\u00e9 o pacote cliente PostgreSQL ser instalado.'
        'db_sum_engine' = 'Base de dados: {0}'
        'db_sum_local' = 'O PostgreSQL corre nesta m\u00e1quina (apenas loopback); base {0}, utilizador {1} (sem direitos de administra\u00e7\u00e3o)'
        'db_sum_remote' = 'Servidor PostgreSQL existente; base {0}, utilizador {1}'
        'db_sum_schema' = 'Esquema: {0}'
        'db_sum_secret' = 'A liga\u00e7\u00e3o (com a palavra-passe) est\u00e1 em {0}, leg\u00edvel apenas pelo servi\u00e7o ToutWAF'
        'db_sum_backup' = 'Todas as noites corre um pg_dump verificado (guardam-se 7); estado na consola, Sant\u00e9'
        'db_sum_nobackup' = 'Sem c\u00f3pia autom\u00e1tica da base: agende o pg_dump ou use a c\u00f3pia do seu fornecedor de base de dados'
        'db_sum_sqlite' = 'Base de dados: SQLite, um ficheiro nesta m\u00e1quina (instala\u00e7\u00e3o pequena). Passar para PostgreSQL mais tarde: toutwaf-cp db migrate'
        's_extras' = 'Extras: agente Windows e programas do antiv\u00edrus'
        's_extras_ok' = 'Extras instalados: {0} programas em {1}'
        's_extras_sha' = 'Extras verificados: {0} ficheiro(s), {1} MiB (SHA-256 e assinatura)'
        's_extras_unchecked' = 'Extras usados tal como est\u00e3o, sem SHA256SUMS para os verificar: {0}'
        'w_extras_dl' = 'N\u00e3o foi poss\u00edvel transferir os extras ({0}). O ToutWAF funciona sem eles, mas esta consola n\u00e3o oferecer\u00e1 o Windows nem o antiv\u00edrus enquanto n\u00e3o estiverem instalados.'
        'w_extras_sum' = 'Os extras {0} n\u00e3o correspondem ao seu SHA-256 no SHA256SUMS assinado: N\u00c3O foram instalados.'
        'w_extras_bad' = 'O ficheiro de extras {0} n\u00e3o \u00e9 um arquivo de extras v\u00e1lido: N\u00c3O foi instalado.'
        'w_extras_ver' = 'Os extras s\u00e3o da vers\u00e3o {0}, esta instala\u00e7\u00e3o \u00e9 {1}: N\u00c3O foram instalados.'
        'w_extras_inc' = 'A vers\u00e3o lista {0} parte(s) dos extras mas indica {1}: a publica\u00e7\u00e3o est\u00e1 danificada, os extras N\u00c3O foram instalados.'
        'w_extras_nofile' = 'O ficheiro de extras {0} n\u00e3o existe.'
        'w_extras_none' = 'Esta vers\u00e3o n\u00e3o inclui extras: esta consola n\u00e3o oferecer\u00e1 o Windows nem o antiv\u00edrus.'
        'w_extras_todo' = 'Extras n\u00e3o instalados. Quando a rede o permitir, execute como root: {0}'
        'extras_needs_cp' = 'Os extras pertencem ao plano de controlo: n\u00e3o est\u00e1 instalado nesta m\u00e1quina.'
        'extras_other_release' = 'A vers\u00e3o publicada ({0}) n\u00e3o \u00e9 a instalada ({1}): os extras v\u00eam com ela. Execute --update.'
        'st_extras_ok' = 'Extras: instalados (agente Windows, programas do antiv\u00edrus)'
        'st_extras_none' = 'Extras em falta: o Windows e o antiv\u00edrus n\u00e3o s\u00e3o oferecidos. Execute como root: {0}'
    }
    'nl' = @{
        'tagline' = 'Bescherming van webapplicaties en API''s'
        'menu_title' = 'Wat wilt u doen?'
        'opt_install' = 'Installeren (control plane + data plane + console)'
        'opt_install_d' = 'Alles op deze machine: webconsole, beleidsopslag en reverse proxy / WAF.'
        'opt_cp' = 'Alleen de control plane installeren'
        'opt_cp_d' = 'Webconsole, API en beleidsopslag. Data planes (nodes) sluiten later aan.'
        'opt_dp' = 'Alleen een data plane installeren'
        'opt_dp_d' = 'Reverse-proxy- / WAF-node die zich bij een bestaande control plane voegt (vraagt om URL en inschrijftoken).'
        'opt_update' = 'Bijwerken'
        'opt_update_d' = 'Downloadt een nieuwere versie, controleert (SHA-256 / sigstore), maakt een back-up, behoudt configuratie en data en draait terug bij mislukking.'
        'opt_uninstall' = 'Verwijderen'
        'opt_uninstall_d' = 'Verwijdert ToutWAF; u kiest of configuratie, data en logs bewaard of gewist worden.'
        'opt_status' = 'Status en gezondheidscontrole'
        'opt_status_d' = 'Ge\u00efnstalleerde versies, services, luisterpoorten en health-endpoints.'
        'opt_links' = 'Paneellinks opnieuw tonen'
        'opt_links_d' = 'Paneel-URL''s, eenmalige installatielink en de in de firewall te openen poorten.'
        'opt_quit' = 'Afsluiten'
        'choice' = 'Uw keuze'
        'invalid_choice' = 'Ongeldige keuze.'
        'state_installed' = 'Ge\u00efnstalleerd: {0}'
        'state_none' = 'ToutWAF is niet ge\u00efnstalleerd op deze machine.'
        'cfg_title' = 'Installatie-opties (Enter = standaard)'
        'q_cp_url' = 'URL van de control plane (bv. https://cp.example.com:9444)'
        'q_token' = 'Inschrijftoken (console: Nodes > Node toevoegen)'
        'q_cp_ca' = 'PEM-bestand van de CA / het certificaat van de control plane (leeg = systeemopslag)'
        'q_cp_port' = 'Consolepoort'
        'q_http_port' = 'HTTP-poort'
        'q_https_port' = 'HTTPS-poort'
        'q_public_host' = 'Publieke hostnaam of IP-adres (leeg = automatisch)'
        'q_firewall' = 'Firewall automatisch openen (firewalld / ufw)?'
        'q_boot' = 'Services bij het opstarten starten?'
        'q_channel' = 'Releasekanaal (stable / dev)'
        'q_bindir' = 'Installatiemap'
        'q_confirm' = 'Doorgaan met de installatie?'
        'q_purge' = 'Ook configuratie, data en logs wissen? (Nee = bewaren)'
        'q_confirm_un' = 'ToutWAF echt verwijderen?'
        'aborted' = 'Afgebroken.'
        'root_required' = 'Voer uit als root (sudo bash install.sh).'
        's_prereq' = 'Vereisten installeren'
        's_fetch' = 'ToutWAF {0} ({1}) downloaden'
        's_sha' = 'SHA-256 gecontroleerd'
        's_sig' = 'cosign-handtekening gecontroleerd'
        'w_nocosign' = 'cosign niet ge\u00efnstalleerd: handtekening niet gecontroleerd (alleen checksum)'
        's_user' = 'Serviceaccount en mappen aanmaken'
        's_bin' = 'Binaries installeren'
        's_cfg' = 'Configuratie schrijven (bestaande bestanden blijven)'
        's_units' = 'systemd-units en systeemtuning installeren'
        's_selinux' = 'SELinux configureren'
        'q_console_from' = 'Console alleen voor dit netwerk openen (CIDR, bv. 203.0.113.0/24; leeg = iedereen)'
        'q_console_from_bad' = 'Geen adres of CIDR (0.0.0.0/0 is hetzelfde als leeg): de consolepoort blijft voor iedereen open.'
        'fw_console_note' = 'De console (poort {0}) bevat de beheerlogin: openen voor heel internet is handig maar blootgesteld.'
        'fw_console_open' = 'Consolepoort {0} staat open voor iedereen: beperk met --console-from CIDR of in de console (Instellingen > Firewall)'
        'fw_console_from' = 'Consolepoort {0} staat alleen open voor {1}'
        'fw_none' = 'Geen actieve firewall (firewalld / ufw / nftables / iptables) gevonden: niets filtert het verkeer, geen poorten te openen'
        'fw_manual' = 'De firewall {0} wordt niet door de installer gewijzigd: voer deze commando''s zelf uit'
        'fw_failed' = 'De firewall kon niet worden geconfigureerd: {0}'
        'home_fresh' = 'Nieuwe installatie: alles komt onder {0} (bin, conf, data, logs)'
        'home_legacy' = 'Bestaande installatie gevonden: de paden blijven (bin {0}, conf {1}, data {2}). Er wordt niets verplaatst; gebruik --home DIR voor de nieuwe indeling.'
        'home_explicit_legacy' = '--home {0} opgegeven terwijl er een installatie bestaat in {1}: de data wordt NIET verplaatst'
        'home_bad' = '--home moet een absoluut pad zijn (letters, cijfers, . _ - + /), niet / en niet onder /proc /sys /dev: {0}'
        'home_noexec' = '{0} staat op een noexec-mount: de programma''s kunnen daar niet draaien, kies een ander --home'
        's_fw' = 'Firewall configureren'
        's_boot' = 'Paneel voorbereiden (beheerdersaccount, beveiligd pad)'
        's_start' = 'Services starten'
        's_health' = 'Wachten tot de services gezond zijn'
        's_backup' = 'Back-up van configuratie en data'
        'w_rollback' = 'De nieuwe versie is niet gezond: terugdraaien naar de vorige'
        'up_to_date' = 'Al bijgewerkt ({0})'
        'not_installed' = 'ToutWAF is niet ge\u00efnstalleerd: niets bij te werken.'
        'st_channel' = 'Kanaal: {0}'
        'st_latest' = 'Laatst beschikbare versie: {0}'
        'st_newer' = 'update beschikbaar: voer uit met --update'
        'e_yanked' = 'Versie {0} is ingetrokken (yanked) en mag niet worden ge\u00efnstalleerd. Gebruik --update voor de huidige versie, of --force om te negeren.'
        'e_nover' = 'Op het kanaal {0} is nog geen versie gepubliceerd, dus er valt niets te installeren. ToutWAF is niet ge\u00efnstalleerd of gewijzigd. Om vanaf het kanaal {1} te installeren, start u het installatieprogramma opnieuw met -Channel {2}.'
        'e_installer_old' = 'Dit installatieprogramma is te oud voor deze versie (vereist versie {0}): download het opnieuw van de kanaal-URL.'
        'up_rebuilt' = 'Zelfde versie, nieuwe build: ge\u00efnstalleerd {0}, beschikbaar {1}. Bezig met bijwerken.'
        'st_newbuild' = 'zelfde versie, nieuwe build beschikbaar: voer opnieuw uit met {0}'
        'st_nochannel' = 'Laatst beschikbare versie: in dit kanaal is nog niets gepubliceerd'
        'w_mirror' = 'De openbare mirror leverde bestanden die niet bij elkaar passen ({0}): hij wordt waarschijnlijk nog bijgewerkt na een publicatie. Het kanaal wordt \u00e9\u00e9n keer opnieuw gelezen.'
        'e_mismatch' = 'checksum klopt niet voor {0} ({1}): het gedownloade bestand komt niet overeen met de gepubliceerde checksum, dus er is niets ge\u00efnstalleerd of gewijzigd. Direct na een publicatie kan de openbare mirror enkele minuten de vorige bestanden aanbieden: wacht vijf minuten en start het installatieprogramma opnieuw. Gebeurt het opnieuw, installeer dan niet: de publicatie is beschadigd.'
        'e_downgrade' = 'De nieuwste versie {0} van kanaal {1} is ouder dan de ge\u00efnstalleerde {2}: gebruik --force om terug te gaan.'
        's_sigok' = 'release-handtekening gecontroleerd, sleutel {0}'
        'w_sigold' = 'versie {0} is zonder handtekening gepubliceerd (versies v\u00f3\u00f3r 0.2.0-dev.7 zijn niet ondertekend): alleen SHA-256 is gecontroleerd, de handtekening kon niet worden gecontroleerd'
        'w_sigskip' = 'release-handtekening NIET gecontroleerd: openssl.exe niet gevonden in PATH (Windows heeft geen ingebouwde Ed25519-controle), alleen SHA-256 is gecontroleerd. Installeer OpenSSL 3 en voer opnieuw uit om te controleren met sleutel {0}'
        'done' = 'Klaar.'
        'failed' = 'Mislukt'
        'log_hint' = 'Volledig logboek: {0}'
        'dry_done' = 'Proefrun: niets is gewijzigd.'
        'sum_title' = 'Samenvatting van de installatie'
        'sum_panel' = 'Paneellinks'
        'sum_tls_note' = 'Alleen HTTPS. Het certificaat is zelfondertekend tot u uw eigen installeert: de browser toont een waarschuwing.'
        'sum_local' = 'Lokale adressen'
        'sum_public' = 'Publiek adres'
        'sum_public_unknown' = 'Het publieke IP kon niet worden gedetecteerd (offline of geblokkeerd). Gebruik het publieke IP of de DNS-naam van uw server in plaats van de lokale adressen, of voer opnieuw uit met --public-host.'
        'sum_admin' = 'Beheerdersaccount'
        'sum_user' = 'Gebruikersnaam'
        'sum_password' = 'Wachtwoord'
        'sum_pw_once' = 'slechts EENMAAL getoond - wijzig het in Instellingen > Toegang / Account'
        'sum_pw_unchanged' = 'ongewijzigd (nooit opnieuw gegenereerd). Reset met: toutwaf-cp admin reset-password --user {0}'
        'sum_setup' = 'Eenmalige installatielink'
        'sum_setup_note' = 'Open hem om de paneellink, het account en het wachtwoord in de webinstallatie in te stellen.'
        'p_dpapi_warn' = 'Poort 9444 (data-plane-API) is NIET geopend: sta alleen toe vanuit uw data-plane-nodes'
        'p_dpapi_only' = '9444/tcp alleen vanuit uw data planes, bijv.:'
        'sum_setup_none' = 'Nu geen installatielink (al uitgegeven, of account bestond al). Maak een nieuwe met: toutwaf-cp setup-link --regenerate'
        'sum_ports' = 'Te openen poorten in de firewall'
        'sum_cmds' = 'Opdrachten'
        'sum_cloud' = 'Cloud / hosting: open deze poorten ook in de beveiligingsgroep / netwerk-ACL van de provider.'
        'sum_file' = 'Samenvatting opgeslagen (alleen root): {0}'
        'sum_fallback' = 'Deze control plane heeft nog geen ''bootstrap''-opdracht: open de console-URL en volg de installatiepagina.'
        'sum_node_hint' = 'Om deze node via de console te beheren: Nodes > Node toevoegen, stel daarna control_plane.url / enroll_token in {0} in.'
        'q_fwmodule' = 'Wilt u dat ToutWAF ook de firewall van deze machine beheert?'
        'fwmod_n1' = 'Optionele module, uit tenzij u ja zegt. Tijdens de installatie wordt niets toegepast: u controleert elke wijziging in de console.'
        's_bkclient' = 'ToutWAF Backup-client wordt ge\u00efnstalleerd (handtekening gecontroleerd)'
        'bkc_done' = 'ToutWAF Backup-client ge\u00efnstalleerd. Volgende stap: console, Back-ups > Back-upservers, om een server te koppelen.'
        'bkc_fail' = 'De ToutWAF Backup-client is NIET ge\u00efnstalleerd ({0}). De installatie gaat door; installeer hem later met --with-backup-client.'
        'bkc_nokey' = 'De ToutWAF Backup-client is NIET ge\u00efnstalleerd: geen publieke releasesleutel. Geef die op met --backup-client-pubkey (of TOUTWAF_BACKUP_PUBKEY, of het bestand backup-release.pub in de configuratiemap); zonder gecontroleerde handtekening wordt niets ge\u00efnstalleerd.'
        'bkc_badsig' = 'De ToutWAF Backup-client is NIET ge\u00efnstalleerd: de handtekening van de release is NIET geldig. Er is niets ge\u00efnstalleerd.'
        'tele_on' = 'Telemetrie: standaard deelt ToutWAF met de ruimte van de uitgever (app.toutwaf.com) de geblokkeerde aanvallen (adres van de aanvaller, land, type aanval, regel), geaggregeerde cijfers en de hostnamen van de beschermde sites. Nooit de inhoud van verzoeken en nooit legitieme bezoekers. Met \u00e9\u00e9n klik uit te zetten in de console (Instellingen, Privacy en telemetrie), of installeer met --no-telemetry (of TOUTWAF_TELEMETRY=0) voor nultelemetrie. Details: docs/confidentialite-telemetrie.md'
        'tele_off' = 'Telemetrie: nultelemetrie is aangevraagd (--no-telemetry / TOUTWAF_TELEMETRY=0). Er wordt niets naar de ruimte van de uitgever gestuurd en niets van hem ontvangen; de console start met de schakelaar \u00abNultelemetrie\u00bb aan. U kunt dit later wijzigen in de console (Instellingen, Privacy en telemetrie).'
        'fwmod_n2' = 'Elke wijziging draait als proef met aftelling en wordt vanzelf teruggedraaid als u haar niet behoudt; een anti-lockout-beveiliging weigert elke regel die SSH of de console zou afsnijden.'
        'fwmod_n3' = 'Dit is niet de vorige vraag, die alleen de poorten opent die ToutWAF nodig heeft in de systeemfirewall (--no-firewall).'
        's_fwmod' = 'Firewallmodule wordt ingeschakeld (geen regel toegepast)'
        'fwmod_done' = 'Firewallmodule ingeschakeld. Er is niets toegepast: open Firewall in de console om regels te bekijken en te proberen.'
        'fwmod_fail' = 'Het firewallmodule kon niet worden ingeschakeld ({0}). De installatie gaat door; schakel het later in via Instellingen > Modules.'
        's_link' = 'Dataplane koppelen aan de console'
        'dp_link_ok' = 'Dataplane automatisch aan de console gekoppeld: niets handmatig te configureren.'
        'dp_link_same' = 'Dataplane is al aan de console gekoppeld; de configuratie is ongewijzigd gelaten.'
        'dp_link_fixed' = 'Dataplane-configuratie hersteld (dubbele control_plane-blokken samengevoegd); het vorige bestand is bewaard.'
        'dp_link_remote' = 'Het dataplane op deze machine is voor een andere console geconfigureerd en is ongewijzigd gelaten.'
        'dp_link_fail' = 'Het dataplane kon niet automatisch aan de console worden gekoppeld: {0}'
        'dp_link_fail_hint' = 'Het dataplane behoudt zijn zelfstandige configuratie, dus sites antwoorden met HTTP 421 tot het is gekoppeld. Los de oorzaak hierboven op en voer dit installatieprogramma opnieuw uit: het koppelt de node zelf.'
        'st_title' = 'Status'
        'st_healthy' = 'gezond'
        'st_unhealthy' = 'NIET gezond'
        'st_active' = 'actief'
        'st_inactive' = 'inactief'
        'st_listening' = 'luistert'
        'st_closed' = 'luistert niet'
        'un_title' = 'ToutWAF verwijderen'
        'un_kept' = 'Configuratie bewaard in {0}, data in {1} (gebruik --purge om te wissen).'
        'un_purged' = 'Configuratie, data en logs gewist.'
        'p_console' = 'webconsole + API'
        'p_http' = 'HTTP (reverse proxy)'
        'p_https' = 'HTTPS (reverse proxy)'
        'p_dpapi' = 'data-plane-API: ALLEEN als data planes op ANDERE hosts draaien (beperk tot hun IP''s)'
        'w_fw_manual' = 'Poort {0}/tcp is niet automatisch geopend: zie de opdrachten in de samenvatting.'
        'need_cp' = 'Met een inschrijftoken is een control-plane-URL nodig.'
        'cp_title' = 'Systeemcompatibiliteit'
        'cp_detected' = 'Gedetecteerd: {0}, arch {1}, glibc {2}, systemd {3}, kernel {4}'
        'cp_ok' = 'Compatibel: {0} ({1})'
        'cp_tested' = 'getest'
        'cp_expected' = 'verwacht'
        'cp_w_like' = '{0} staat niet in de compatibiliteitstabel: behandeld als de familie {1} (verwacht). Er wordt doorgegaan.'
        'cp_w_newer' = '{0} {1} is nieuwer dan de vermelde versies: nog niet gevalideerd (verwacht). Er wordt doorgegaan.'
        'cp_w_unlisted' = '{0} {1} staat niet in de tabel: behandeld als verwacht. Er wordt doorgegaan.'
        'cp_w_nover' = '{0} meldt geen versie (rolling of testing): behandeld als verwacht. Er wordt doorgegaan.'
        'cp_w_glibc' = 'De glibc-versie kon niet worden bepaald; er wordt doorgegaan.'
        'cp_w_skip' = '--skip-os-check: de compatibiliteitscontrole wordt overgeslagen. Dit systeem wordt NIET ondersteund: doorgaan op eigen risico.'
        'cp_w_stage' = 'Staging (--destdir): het compatibiliteitsoordeel is slechts informatief, er wordt niets geweigerd.'
        'cp_refused' = 'Dit systeem is niet compatibel met ToutWAF:'
        'cp_r_old' = '{0} {1} is ouder dan de minimaal ondersteunde versie ({2}).'
        'cp_r_eol' = '{0} {1} is end-of-life, of de glibc / systemd is te oud.'
        'cp_r_glibc' = 'glibc {0} gevonden: {1} of nieuwer is vereist.'
        'cp_r_musl' = 'musl libc gevonden: glibc {0} of nieuwer is vereist.'
        'cp_r_init' = '{0} {1} gebruikt geen systemd, dat ToutWAF vereist.'
        'cp_r_immutable' = '{0} {1} heeft een onveranderlijk root-bestandssysteem (niet ondersteund).'
        'cp_r_layout' = '{0} {1} volgt niet de standaard Linux-mapstructuur (niet ondersteund).'
        'cp_r_arch' = 'Architectuur {0} wordt niet ondersteund (ondersteund: {1}).'
        'cp_r_distro_arch' = '{0} {1} draait op een architectuur zonder ToutWAF-build.'
        'cp_r_systemd' = 'systemd draait niet als init-systeem (/run/systemd/system ontbreekt): het is vereist voor de diensten.'
        'cp_r_systemd_old' = 'systemd {0} gevonden: {1} of nieuwer is vereist.'
        'cp_r_kernel' = 'Linux-kernel {0} gevonden: {1} of nieuwer is vereist.'
        'cp_r_unknown' = 'Distributie ''{0}'' wordt niet herkend en vermeldt geen bekende familie (ID_LIKE=''{1}'').'
        'cp_r_noosr' = '/etc/os-release ontbreekt: de distributie kan niet worden herkend.'
        'cp_nochange' = 'Er is niets gewijzigd op dit systeem.'
        'cp_list' = 'Compatibele systemen (amd64 en arm64, glibc {0} of nieuwer, systemd {1} of nieuwer):'
        'cp_rolling' = 'rolling'
        'cp_any' = 'elke versie'
        'cp_override' = 'Toch installeren, op eigen risico: --skip-os-check. Details: docs/install/platforms.md'
        'cp_not_root' = 'Niet als root uitgevoerd: gebruik sudo om te installeren (de controle zelf heeft geen root nodig).'
        'sum_compat' = 'Compatibiliteit'
        'cp_prereq_arch' = 'De pakketdatabases zijn niet gesynchroniseerd. Voer eerst ''pacman -Syu'' uit (een gedeeltelijke update wordt op Arch niet ondersteund) en start het installatieprogramma opnieuw.'
        'cp_wdetected' = 'Gedetecteerd: {0} (build {1}), arch {2}'
        'cp_wlist' = 'Compatibele Windows-versies (amd64 en arm64; arm64 niet getest op echte hardware):'
        'cp_r_arm32' = '32-bits ARM (armv7) wordt niet ondersteund door ToutWAF. Installeer een 64-bits besturingssysteem (Raspberry Pi OS 64-bit, Ubuntu of Debian arm64; Raspberry Pi 3, 4, 5 of Zero 2 W) en start het installatieprogramma opnieuw.'
        'cp_r_arm_userland32' = 'De kernel is 64-bits maar het systeem (userland) is 32-bits. ToutWAF vereist een 64-bits besturingssysteem: installeer opnieuw met Raspberry Pi OS 64-bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) of Ubuntu / Debian arm64.'
        'cp_w_pi' = 'Raspberry Pi gedetecteerd: arm64 is alleen onder emulatie getest, niet op echte hardware. Zet data en logs op een SSD / USB-schijf in plaats van op de SD-kaart en vermijd de alles-in-\u00e9\u00e9n-installatie onder 2 GB RAM (zie docs/install/raspberry-pi.md).'
        'pf_title' = 'Controle van wat deze machine nodig heeft'
        'pf_ok' = 'Niets staat in de weg: de poorten die ToutWAF nodig heeft zijn vrij.'
        'pf_refused' = 'ToutWAF kan niet op deze machine worden ge\u00efnstalleerd zoals ze nu is. Er is niets gewijzigd.'
        'pf_ok_warn' = 'Niets verhindert de installatie, maar lees de punten hierboven.'
        'pf_l_refuse' = 'geweigerd'
        'pf_l_warn' = 'let op'
        'pf_l_info' = 'opmerking'
        'pf_port_busy' = 'Poort {0} wordt al gebruikt door {1}.'
        'pf_prog_other' = 'een ander programma'
        'pf_prog_unknown' = 'een ander programma (de naam kon niet worden gelezen)'
        'pf_act_web' = 'ToutWAF heeft poort {0} en {1} nodig om uw sites te beschermen. Stop dat programma of verplaats het naar andere poorten (ToutPanel zet, naast ToutWAF ge\u00efnstalleerd, zijn webserver op 8080 en 8443) en start het installatieprogramma opnieuw.'
        'pf_act_console' = 'De console van ToutWAF heeft deze poort nodig. Maak de poort vrij of kies een andere consolepoort (het installatieprogramma vraagt ernaar in zijn menu) en start het installatieprogramma opnieuw.'
        'pf_act_agent' = 'ToutWAF gebruikt deze poort voor de data planes en agents die er verbinding mee maken. Maak de poort vrij en start het installatieprogramma opnieuw.'
        'pf_act_admin' = 'De data plane gebruikt deze poort alleen op deze machine, voor zijn eigen gezondheidscontrole. Maak de poort vrij en start het installatieprogramma opnieuw.'
        'pf_nostart' = '(er wordt nu niets gestart, dus dit wordt alleen gemeld)'
        'pf_boot' = '{0} is ge\u00efnstalleerd en start met de machine, hoewel het nu gestopt is. Bij de volgende herstart zou het poort {1} en {2} bezetten v\u00f3\u00f3r ToutWAF.'
        'pf_act_boot' = 'Schakel het uit zodat het niet met de machine start, of verplaats het naar andere poorten, v\u00f3\u00f3r de machine opnieuw start.'
        'pf_fw_cause' = 'Een firewall ({0}) is actief en laat poort {1} en {2} niet door, en het installatieprogramma mag hem niet wijzigen.'
        'pf_fw_action' = 'Open deze poorten in de firewall of laat het installatieprogramma het doen (zonder de optie --no-firewall). Anders zijn uw sites van buitenaf niet bereikbaar.'
        'pf_fwx_cause' = 'De firewall van deze machine ({0}) weigert inkomende verbindingen standaard en heeft geen regel voor poort {1} en {2}.'
        'pf_fwx_action' = 'ToutWAF wijzigt de regels van dit soort firewall nooit zelf: open deze poorten in de configuratie ervan en controleer daarna uw sites.'
        'pf_cp_cause' = 'De control plane {0} is vanaf deze machine niet bereikbaar.'
        'pf_cp_action' = 'Controleer het adres, of de control plane draait en of zijn firewall deze machine toelaat (standaard poort 9444) en start het installatieprogramma opnieuw.'
        'pf_router_cause' = 'Deze machine heeft een priv\u00e9adres ({0}): ze staat waarschijnlijk achter een router.'
        'pf_router_action' = 'Na de installatie toont ToutWAF welke poorten naar deze machine doorgestuurd moeten worden en geeft het de bestanden voor de gangbare routers. Nu hoeft u niets voor te bereiden.'
        'pf_skipped' = 'De controle van de omgeving is op uw verzoek overgeslagen: wat in de weg staat laat de installatie of de start later mislukken.'
        's_sysupdate' = 'Systeempakketten worden bijgewerkt (dit kan enkele minuten duren)'
        'su_skipped' = 'De systeempakketten worden niet eerst bijgewerkt (TOUTWAF_SKIP_SYSUPDATE).'
        'su_recent' = 'De systeempakketten zijn minder dan 6 uur geleden bijgewerkt: niet herhaald.'
        'su_dry' = 'de systeempakketten zouden eerst worden bijgewerkt (overslaan met TOUTWAF_SKIP_SYSUPDATE=1)'
        'su_nopm' = 'Geen ondersteunde pakketbeheerder om het systeem bij te werken: overgeslagen, de installatie gaat door.'
        'su_failed' = 'Het bijwerken van de systeempakketten is mislukt (code {0}); de installatie gaat zonder verder. Details: {1}. Oplossing: voer de update zelf uit en lees de foutmelding (kapotte repository? draait er een andere pakketbeheerder?), of voer dit commando opnieuw uit met TOUTWAF_SKIP_SYSUPDATE=1.'
        'su_reboot' = 'Een herstart van deze server is nodig om de systeemupdate af te ronden (nieuwe kernel of bibliotheken). ToutWAF herstart hem nooit voor u: doe het wanneer het kan.'
        'q_sysupdate' = 'Eerst de systeempakketten bijwerken (aanbevolen)?'
        'pr_disk_full' = 'Slechts {0} MB vrij op {1} (minstens {2} MB nodig): de installatie zou niet kunnen worden voltooid.'
        'pr_disk_full_a' = 'Maak ruimte vrij (pakketcache: apt-get clean of dnf clean all; oude logs: journalctl --vacuum-size=100M) en voer dit commando opnieuw uit. Toch doorgaan: TOUTWAF_SKIP_PREREQ=1.'
        'pr_disk_full_w_a' = 'Maak ruimte vrij (Schijfopruiming, prullenbak legen) en voer dit commando opnieuw uit. Toch doorgaan: $env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = 'Slechts {0} MB vrij op {1} (ongeveer {2} MB is comfortabel).'
        'pr_disk_low_a' = 'Maak ruimte vrij of voeg schijfruimte toe; de installatie kan doorgaan.'
        'pr_dns' = 'Deze machine kan de naam {0} niet omzetten (DNS).'
        'pr_dns_a' = 'Controleer de DNS-servers (cat /etc/resolv.conf, resolvectl status), voeg een werkende toe, bijvoorbeeld nameserver 9.9.9.9, en voer dit commando opnieuw uit.'
        'pr_dns_w_a' = 'Controleer de DNS-servers met ''ipconfig /all'', stel een werkende in (bijvoorbeeld 9.9.9.9) bij de instellingen van de netwerkadapter en voer dit commando opnieuw uit.'
        'pr_clock' = 'De klok van deze machine wijkt {0} seconden af van de internettijd: TLS-certificaten en handtekeningen mislukken bij een verkeerde klok.'
        'pr_clock_a' = 'Synchroniseer de klok: timedatectl set-ntp true (of chronyc makestep), controleer met timedatectl en voer dit commando opnieuw uit.'
        'pr_clock_w_a' = 'Synchroniseer de klok: w32tm /resync (of Instellingen > Tijd en taal > Nu synchroniseren) en voer dit commando opnieuw uit.'
        'pr_ok' = 'Schijfruimte, DNS en klok zijn in orde.'
        'cloud_https' = '--cloud-url moet een https://-adres zijn (de node praat nooit onversleuteld met de cloud).'
        'cloud_dp_only' = '--cloud-url installeert een beschermingsnode: gebruik het met --component dp (de standaard in cloudmodus).'
        'cloud_need_token' = 'Een registratietoken is nodig om deze node met uw account te verbinden (--enroll-token; console: Nodes > Mijn eerste node toevoegen).'
        'cloud_ca_local' = '--cloud-ca moet een lokaal bestand zijn.'
        'cloud_nolink' = 'Deze versie bevat de ToutWAF Cloud-koppeling (toutwaf-cloudlink) niet: werk het installatieprogramma bij of gebruik een nieuwere versie.'
        'cloud_enrol_failed' = 'De node kon niet bij uw account worden geregistreerd (zie de regels hierboven). Het token is misschien gebruikt of verlopen: maak een nieuw token in de console.'
        'pf_cloud_action' = 'Sta deze machine toe het adres van uw ToutWAF Cloud op poort 443 te bereiken (alleen uitgaand), of stel HTTPS_PROXY in als een proxy nodig is. Inkomend hoeft niets open.'
        's_db' = 'Database voorbereiden'
        'db_choose' = 'Welke database moet ToutWAF gebruiken?'
        'db_opt_pg' = 'PostgreSQL (aanbevolen)'
        'db_opt_pg_local' = 'PostgreSQL op deze machine installeren (voor u aangemaakt en ingesteld)'
        'db_opt_pg_remote' = 'Bestaande PostgreSQL-server gebruiken (getest en, indien toegestaan, voorbereid)'
        'db_opt_sqlite' = 'SQLite (kleine installatie, slechts \u00e9\u00e9n server)'
        'db_sqlite_note' = 'SQLite is \u00e9\u00e9n bestand op deze machine: prima voor een kleine installatie op \u00e9\u00e9n server. Het kan niet door meerdere control planes worden gedeeld en heeft geen replicatie. U kunt later overstappen naar PostgreSQL met: toutwaf-cp db migrate.'
        'db_q_host' = 'PostgreSQL-host'
        'db_q_port' = 'Poort'
        'db_q_name' = 'Naam van de database'
        'db_q_user' = 'Databasegebruiker'
        'db_q_pw' = 'Wachtwoord van die gebruiker (leeg als een beheerdersaccount hem aanmaakt)'
        'db_q_tls' = 'TLS-modus (disable, prefer, require, verify-ca, verify-full)'
        'db_q_ca' = 'CA-certificaatbestand van de server (voor verify-ca / verify-full)'
        'db_q_admin' = 'Beheerdersaccount dat gebruiker en database aanmaakt (leeg = bestaan al)'
        'db_q_adminpw' = 'Wachtwoord van het beheerdersaccount (eenmalig gebruikt, nooit opgeslagen)'
        'db_hint' = 'Database: SQLite (standaard). Voor een serverinstallatie of meerdere control planes gebruikt u --db postgres (--db-install-local installeert het voor u).'
        'db_no_pkg' = 'PostgreSQL kan op dit systeem niet automatisch worden ge\u00efnstalleerd: installeer zelf het serverpakket en start het installatieprogramma opnieuw met --db postgres.'
        'db_install_failed' = 'Het installeren van het PostgreSQL-pakket is mislukt. Het logboek zegt waarom (/var/log/toutwaf-install.log).'
        'db_init_failed' = 'Het PostgreSQL-cluster kon niet worden ge\u00efnitialiseerd. Het logboek zegt waarom.'
        'db_start_failed' = 'PostgreSQL start niet. Controleer: systemctl status postgresql en het logboek.'
        'db_too_old' = 'De hier ge\u00efnstalleerde PostgreSQL-versie ({0}) is te oud: versie 13 of nieuwer is vereist.'
        'db_exists' = 'Er bestaat al een gebruiker "{0}" of database "{1}" die niet door dit installatieprogramma is aangemaakt: er is niets gewijzigd. Kies andere namen (--db-name, --db-user) of geef de bestaande verbinding op (--db-dsn-file).'
        'db_create_failed' = 'De gebruiker of database kon niet worden aangemaakt. Wat was aangemaakt is weer verwijderd.'
        'db_rights' = 'Het account heeft hiervoor geen rechten. De bovenstaande opdrachten zijn het minimum dat een serverbeheerder moet uitvoeren; start daarna het installatieprogramma opnieuw.'
        'db_need_conn' = 'Er is geen verbinding met de PostgreSQL-server opgegeven: gebruik --db-dsn-file, of --db-host met --db-password-file, of --db-install-local.'
        'db_schema_failed' = 'De tabellen konden niet in de database worden aangemaakt. Het logboek zegt waarom.'
        'db_no_pgdump' = 'pg_dump ontbreekt: de dagelijkse databaseback-up meldt een fout totdat het PostgreSQL-clientpakket is ge\u00efnstalleerd.'
        'db_sum_engine' = 'Database: {0}'
        'db_sum_local' = 'PostgreSQL draait op deze machine (alleen loopback); database {0}, gebruiker {1} (zonder beheerdersrechten)'
        'db_sum_remote' = 'Bestaande PostgreSQL-server; database {0}, gebruiker {1}'
        'db_sum_schema' = 'Schema: {0}'
        'db_sum_secret' = 'De verbinding (met wachtwoord) staat in {0}, alleen leesbaar voor de ToutWAF-dienst'
        'db_sum_backup' = 'Elke nacht draait een gecontroleerde pg_dump (7 bewaard); status in de console, Sant\u00e9'
        'db_sum_nobackup' = 'Geen automatische databaseback-up: plan pg_dump in of gebruik de back-up van uw databaseaanbieder'
        'db_sum_sqlite' = 'Database: SQLite, \u00e9\u00e9n bestand op deze machine (kleine installatie). Later overstappen naar PostgreSQL: toutwaf-cp db migrate'
        's_extras' = 'Extra''s: Windows-agent en antivirusprogramma''s'
        's_extras_ok' = 'Extra''s ge\u00efnstalleerd: {0} programma''s in {1}'
        's_extras_sha' = 'Extra''s gecontroleerd: {0} bestand(en), {1} MiB (SHA-256 en handtekening)'
        's_extras_unchecked' = 'Extra''s zoals ze zijn overgenomen, zonder SHA256SUMS om ze te controleren: {0}'
        'w_extras_dl' = 'De extra''s konden niet worden gedownload ({0}). ToutWAF werkt zonder, maar deze console biedt geen Windows of antivirus aan zolang ze niet ge\u00efnstalleerd zijn.'
        'w_extras_sum' = 'De extra''s {0} komen niet overeen met hun SHA-256 in de ondertekende SHA256SUMS: ze zijn NIET ge\u00efnstalleerd.'
        'w_extras_bad' = 'Het extra-bestand {0} is geen geldig extra-archief: het is NIET ge\u00efnstalleerd.'
        'w_extras_ver' = 'De extra''s zijn van versie {0}, deze installatie is {1}: ze zijn NIET ge\u00efnstalleerd.'
        'w_extras_inc' = 'De versie vermeldt {0} deel/delen van de extra''s maar zegt er {1} te hebben: de publicatie is beschadigd, de extra''s zijn NIET ge\u00efnstalleerd.'
        'w_extras_nofile' = 'Het extra-bestand {0} bestaat niet.'
        'w_extras_none' = 'Deze versie bevat geen extra''s: deze console biedt geen Windows of antivirus aan.'
        'w_extras_todo' = 'Extra''s niet ge\u00efnstalleerd. Zodra het netwerk het toelaat, voer uit als root: {0}'
        'extras_needs_cp' = 'De extra''s horen bij de control plane: die is niet ge\u00efnstalleerd op deze machine.'
        'extras_other_release' = 'De gepubliceerde versie ({0}) is niet de ge\u00efnstalleerde ({1}): de extra''s komen daarmee mee. Voer --update uit.'
        'st_extras_ok' = 'Extra''s: ge\u00efnstalleerd (Windows-agent, antivirusprogramma''s)'
        'st_extras_none' = 'Extra''s ontbreken: Windows en antivirus worden niet aangeboden. Voer uit als root: {0}'
    }
    'ru' = @{
        'tagline' = '\u0417\u0430\u0449\u0438\u0442\u0430 \u0432\u0435\u0431-\u043f\u0440\u0438\u043b\u043e\u0436\u0435\u043d\u0438\u0439 \u0438 API'
        'menu_title' = '\u0427\u0442\u043e \u0432\u044b \u0445\u043e\u0442\u0438\u0442\u0435 \u0441\u0434\u0435\u043b\u0430\u0442\u044c?'
        'opt_install' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c (control plane + data plane + \u043a\u043e\u043d\u0441\u043e\u043b\u044c)'
        'opt_install_d' = '\u0412\u0441\u0451 \u043d\u0430 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435: \u0432\u0435\u0431-\u043a\u043e\u043d\u0441\u043e\u043b\u044c, \u0445\u0440\u0430\u043d\u0438\u043b\u0438\u0449\u0435 \u043f\u043e\u043b\u0438\u0442\u0438\u043a \u0438 reverse proxy / WAF.'
        'opt_cp' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c \u0442\u043e\u043b\u044c\u043a\u043e control plane'
        'opt_cp_d' = '\u0412\u0435\u0431-\u043a\u043e\u043d\u0441\u043e\u043b\u044c, API \u0438 \u0445\u0440\u0430\u043d\u0438\u043b\u0438\u0449\u0435 \u043f\u043e\u043b\u0438\u0442\u0438\u043a. Data plane (\u0443\u0437\u043b\u044b) \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0430\u044e\u0442\u0441\u044f \u043f\u043e\u0437\u0436\u0435.'
        'opt_dp' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c \u0442\u043e\u043b\u044c\u043a\u043e data plane'
        'opt_dp_d' = '\u0423\u0437\u0435\u043b reverse proxy / WAF, \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0430\u0435\u043c\u044b\u0439 \u043a \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0449\u0435\u043c\u0443 control plane (\u0437\u0430\u043f\u0440\u043e\u0441\u0438\u0442 URL \u0438 \u0442\u043e\u043a\u0435\u043d \u0440\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0446\u0438\u0438).'
        'opt_update' = '\u041e\u0431\u043d\u043e\u0432\u0438\u0442\u044c'
        'opt_update_d' = '\u0421\u043a\u0430\u0447\u0438\u0432\u0430\u0435\u0442 \u043d\u043e\u0432\u0443\u044e \u0432\u0435\u0440\u0441\u0438\u044e, \u043f\u0440\u043e\u0432\u0435\u0440\u044f\u0435\u0442 (SHA-256 / sigstore), \u0434\u0435\u043b\u0430\u0435\u0442 \u0440\u0435\u0437\u0435\u0440\u0432\u043d\u0443\u044e \u043a\u043e\u043f\u0438\u044e, \u0441\u043e\u0445\u0440\u0430\u043d\u044f\u0435\u0442 \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438 \u0438 \u0434\u0430\u043d\u043d\u044b\u0435, \u043f\u0440\u0438 \u0441\u0431\u043e\u0435 \u043e\u0442\u043a\u0430\u0442\u044b\u0432\u0430\u0435\u0442.'
        'opt_uninstall' = '\u0423\u0434\u0430\u043b\u0438\u0442\u044c'
        'opt_uninstall_d' = '\u0423\u0434\u0430\u043b\u044f\u0435\u0442 ToutWAF; \u0432\u044b \u0432\u044b\u0431\u0438\u0440\u0430\u0435\u0442\u0435, \u0441\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c \u0438\u043b\u0438 \u0443\u0434\u0430\u043b\u0438\u0442\u044c \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438, \u0434\u0430\u043d\u043d\u044b\u0435 \u0438 \u0436\u0443\u0440\u043d\u0430\u043b\u044b.'
        'opt_status' = '\u0421\u043e\u0441\u0442\u043e\u044f\u043d\u0438\u0435 \u0438 \u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0430 \u0440\u0430\u0431\u043e\u0442\u043e\u0441\u043f\u043e\u0441\u043e\u0431\u043d\u043e\u0441\u0442\u0438'
        'opt_status_d' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043d\u044b\u0435 \u0432\u0435\u0440\u0441\u0438\u0438, \u0441\u043b\u0443\u0436\u0431\u044b, \u0441\u043b\u0443\u0448\u0430\u044e\u0449\u0438\u0435 \u043f\u043e\u0440\u0442\u044b \u0438 health-\u044d\u043d\u0434\u043f\u043e\u0438\u043d\u0442\u044b.'
        'opt_links' = '\u041f\u043e\u043a\u0430\u0437\u0430\u0442\u044c \u0441\u0441\u044b\u043b\u043a\u0438 \u043d\u0430 \u043f\u0430\u043d\u0435\u043b\u044c \u0435\u0449\u0451 \u0440\u0430\u0437'
        'opt_links_d' = '\u0410\u0434\u0440\u0435\u0441\u0430 \u043f\u0430\u043d\u0435\u043b\u0438, \u043e\u0434\u043d\u043e\u0440\u0430\u0437\u043e\u0432\u0430\u044f \u0441\u0441\u044b\u043b\u043a\u0430 \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438 \u0438 \u043f\u043e\u0440\u0442\u044b \u0434\u043b\u044f \u043e\u0442\u043a\u0440\u044b\u0442\u0438\u044f \u0432 \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u0435.'
        'opt_quit' = '\u0412\u044b\u0439\u0442\u0438'
        'choice' = '\u0412\u0430\u0448 \u0432\u044b\u0431\u043e\u0440'
        'invalid_choice' = '\u041d\u0435\u0432\u0435\u0440\u043d\u044b\u0439 \u0432\u044b\u0431\u043e\u0440.'
        'state_installed' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e: {0}'
        'state_none' = 'ToutWAF \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d \u043d\u0430 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435.'
        'cfg_title' = '\u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u044b \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438 (Enter = \u043f\u043e \u0443\u043c\u043e\u043b\u0447\u0430\u043d\u0438\u044e)'
        'q_cp_url' = 'URL control plane (\u043d\u0430\u043f\u0440. https://cp.example.com:9444)'
        'q_token' = '\u0422\u043e\u043a\u0435\u043d \u0440\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0446\u0438\u0438 (\u043a\u043e\u043d\u0441\u043e\u043b\u044c: \u0423\u0437\u043b\u044b > \u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c \u0443\u0437\u0435\u043b)'
        'q_cp_ca' = 'PEM-\u0444\u0430\u0439\u043b CA / \u0441\u0435\u0440\u0442\u0438\u0444\u0438\u043a\u0430\u0442\u0430 control plane (\u043f\u0443\u0441\u0442\u043e = \u0441\u0438\u0441\u0442\u0435\u043c\u043d\u043e\u0435 \u0445\u0440\u0430\u043d\u0438\u043b\u0438\u0449\u0435)'
        'q_cp_port' = '\u041f\u043e\u0440\u0442 \u043a\u043e\u043d\u0441\u043e\u043b\u0438'
        'q_http_port' = '\u041f\u043e\u0440\u0442 HTTP'
        'q_https_port' = '\u041f\u043e\u0440\u0442 HTTPS'
        'q_public_host' = '\u041f\u0443\u0431\u043b\u0438\u0447\u043d\u043e\u0435 \u0438\u043c\u044f \u0445\u043e\u0441\u0442\u0430 \u0438\u043b\u0438 IP (\u043f\u0443\u0441\u0442\u043e = \u0430\u0432\u0442\u043e\u043e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u0438\u0435)'
        'q_firewall' = '\u0410\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u0438 \u043e\u0442\u043a\u0440\u044b\u0442\u044c \u043f\u043e\u0440\u0442\u044b \u0432 \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u0435 (firewalld / ufw)?'
        'q_boot' = '\u0417\u0430\u043f\u0443\u0441\u043a\u0430\u0442\u044c \u0441\u043b\u0443\u0436\u0431\u044b \u043f\u0440\u0438 \u0437\u0430\u0433\u0440\u0443\u0437\u043a\u0435?'
        'q_channel' = '\u041a\u0430\u043d\u0430\u043b \u0440\u0435\u043b\u0438\u0437\u043e\u0432 (stable / dev)'
        'q_bindir' = '\u041a\u0430\u0442\u0430\u043b\u043e\u0433 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438'
        'q_confirm' = '\u041d\u0430\u0447\u0430\u0442\u044c \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0443?'
        'q_purge' = '\u0423\u0434\u0430\u043b\u0438\u0442\u044c \u0442\u0430\u043a\u0436\u0435 \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438, \u0434\u0430\u043d\u043d\u044b\u0435 \u0438 \u0436\u0443\u0440\u043d\u0430\u043b\u044b? (\u041d\u0435\u0442 = \u0441\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c)'
        'q_confirm_un' = '\u0414\u0435\u0439\u0441\u0442\u0432\u0438\u0442\u0435\u043b\u044c\u043d\u043e \u0443\u0434\u0430\u043b\u0438\u0442\u044c ToutWAF?'
        'aborted' = '\u041e\u0442\u043c\u0435\u043d\u0435\u043d\u043e.'
        'root_required' = '\u0417\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u043e\u0442 root (sudo bash install.sh).'
        's_prereq' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u0437\u0430\u0432\u0438\u0441\u0438\u043c\u043e\u0441\u0442\u0435\u0439'
        's_fetch' = '\u0417\u0430\u0433\u0440\u0443\u0437\u043a\u0430 ToutWAF {0} ({1})'
        's_sha' = 'SHA-256 \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d'
        's_sig' = '\u041f\u043e\u0434\u043f\u0438\u0441\u044c cosign \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u0430'
        'w_nocosign' = 'cosign \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d: \u043f\u043e\u0434\u043f\u0438\u0441\u044c \u043d\u0435 \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u0430 (\u0442\u043e\u043b\u044c\u043a\u043e \u043a\u043e\u043d\u0442\u0440\u043e\u043b\u044c\u043d\u0430\u044f \u0441\u0443\u043c\u043c\u0430)'
        's_user' = '\u0421\u043e\u0437\u0434\u0430\u043d\u0438\u0435 \u0441\u043b\u0443\u0436\u0435\u0431\u043d\u043e\u0439 \u0443\u0447\u0451\u0442\u043d\u043e\u0439 \u0437\u0430\u043f\u0438\u0441\u0438 \u0438 \u043a\u0430\u0442\u0430\u043b\u043e\u0433\u043e\u0432'
        's_bin' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u0438\u0441\u043f\u043e\u043b\u043d\u044f\u0435\u043c\u044b\u0445 \u0444\u0430\u0439\u043b\u043e\u0432'
        's_cfg' = '\u0417\u0430\u043f\u0438\u0441\u044c \u043d\u0430\u0441\u0442\u0440\u043e\u0435\u043a (\u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0449\u0438\u0435 \u0444\u0430\u0439\u043b\u044b \u0441\u043e\u0445\u0440\u0430\u043d\u044f\u044e\u0442\u0441\u044f)'
        's_units' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u044e\u043d\u0438\u0442\u043e\u0432 systemd \u0438 \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0430 \u0441\u0438\u0441\u0442\u0435\u043c\u044b'
        's_selinux' = '\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0430 SELinux'
        'q_console_from' = '\u0420\u0430\u0437\u0440\u0435\u0448\u0438\u0442\u044c \u0434\u043e\u0441\u0442\u0443\u043f \u043a \u043a\u043e\u043d\u0441\u043e\u043b\u0438 \u0442\u043e\u043b\u044c\u043a\u043e \u0438\u0437 \u044d\u0442\u043e\u0439 \u0441\u0435\u0442\u0438 (CIDR, \u043d\u0430\u043f\u0440. 203.0.113.0/24; \u043f\u0443\u0441\u0442\u043e = \u0432\u0441\u0435\u043c)'
        'q_console_from_bad' = '\u041d\u0435 \u0430\u0434\u0440\u0435\u0441 \u0438 \u043d\u0435 CIDR (0.0.0.0/0 \u0440\u0430\u0432\u043d\u043e \u043f\u0443\u0441\u0442\u043e\u043c\u0443): \u043f\u043e\u0440\u0442 \u043a\u043e\u043d\u0441\u043e\u043b\u0438 \u043e\u0441\u0442\u0430\u0451\u0442\u0441\u044f \u043e\u0442\u043a\u0440\u044b\u0442\u044b\u043c \u0434\u043b\u044f \u0432\u0441\u0435\u0445.'
        'fw_console_note' = '\u041a\u043e\u043d\u0441\u043e\u043b\u044c (\u043f\u043e\u0440\u0442 {0}) \u0441\u043e\u0434\u0435\u0440\u0436\u0438\u0442 \u0432\u0445\u043e\u0434 \u0430\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430: \u043e\u0442\u043a\u0440\u044b\u0432\u0430\u0442\u044c \u0435\u0451 \u0432\u0441\u0435\u043c\u0443 \u0418\u043d\u0442\u0435\u0440\u043d\u0435\u0442\u0443 \u0443\u0434\u043e\u0431\u043d\u043e, \u043d\u043e \u043d\u0435\u0431\u0435\u0437\u043e\u043f\u0430\u0441\u043d\u043e.'
        'fw_console_open' = '\u041f\u043e\u0440\u0442 \u043a\u043e\u043d\u0441\u043e\u043b\u0438 {0} \u043e\u0442\u043a\u0440\u044b\u0442 \u0434\u043b\u044f \u0432\u0441\u0435\u0445: \u043e\u0433\u0440\u0430\u043d\u0438\u0447\u044c\u0442\u0435 \u0435\u0433\u043e \u0447\u0435\u0440\u0435\u0437 --console-from CIDR \u0438\u043b\u0438 \u0432 \u043a\u043e\u043d\u0441\u043e\u043b\u0438 (\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438 > \u0411\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440)'
        'fw_console_from' = '\u041f\u043e\u0440\u0442 \u043a\u043e\u043d\u0441\u043e\u043b\u0438 {0} \u043e\u0442\u043a\u0440\u044b\u0442 \u0442\u043e\u043b\u044c\u043a\u043e \u0434\u043b\u044f {1}'
        'fw_none' = '\u0410\u043a\u0442\u0438\u0432\u043d\u044b\u0439 \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440 (firewalld / ufw / nftables / iptables) \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d: \u0442\u0440\u0430\u0444\u0438\u043a \u043d\u0435 \u0444\u0438\u043b\u044c\u0442\u0440\u0443\u0435\u0442\u0441\u044f, \u043e\u0442\u043a\u0440\u044b\u0432\u0430\u0442\u044c \u043f\u043e\u0440\u0442\u044b \u043d\u0435 \u043d\u0443\u0436\u043d\u043e'
        'fw_manual' = '\u0411\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440 {0} \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u044f\u0435\u0442: \u0432\u044b\u043f\u043e\u043b\u043d\u0438\u0442\u0435 \u044d\u0442\u0438 \u043a\u043e\u043c\u0430\u043d\u0434\u044b \u0441\u0430\u043c\u0438'
        'fw_failed' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043d\u0430\u0441\u0442\u0440\u043e\u0438\u0442\u044c \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440: {0}'
        'home_fresh' = '\u041d\u043e\u0432\u0430\u044f \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430: \u0432\u0441\u0451 \u0440\u0430\u0437\u043c\u0435\u0449\u0430\u0435\u0442\u0441\u044f \u0432 {0} (bin, conf, data, logs)'
        'home_legacy' = '\u041e\u0431\u043d\u0430\u0440\u0443\u0436\u0435\u043d\u0430 \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0449\u0430\u044f \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430: \u0435\u0451 \u043f\u0443\u0442\u0438 \u0441\u043e\u0445\u0440\u0430\u043d\u044f\u044e\u0442\u0441\u044f (bin {0}, conf {1}, data {2}). \u041d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u043f\u0435\u0440\u0435\u043d\u043e\u0441\u0438\u0442\u0441\u044f; \u0434\u043b\u044f \u043d\u043e\u0432\u043e\u0439 \u0441\u0445\u0435\u043c\u044b \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0439\u0442\u0435 --home DIR.'
        'home_explicit_legacy' = '--home {0} \u0443\u043a\u0430\u0437\u0430\u043d \u043f\u0440\u0438 \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0449\u0435\u0439 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0435 \u0432 {1}: \u0435\u0451 \u0434\u0430\u043d\u043d\u044b\u0435 \u041d\u0415 \u043f\u0435\u0440\u0435\u043d\u043e\u0441\u044f\u0442\u0441\u044f'
        'home_bad' = '--home \u0434\u043e\u043b\u0436\u0435\u043d \u0431\u044b\u0442\u044c \u0430\u0431\u0441\u043e\u043b\u044e\u0442\u043d\u044b\u043c \u043f\u0443\u0442\u0451\u043c (\u0431\u0443\u043a\u0432\u044b, \u0446\u0438\u0444\u0440\u044b, . _ - + /), \u043d\u0435 / \u0438 \u043d\u0435 \u0432 /proc /sys /dev: {0}'
        'home_noexec' = '{0} \u043d\u0430\u0445\u043e\u0434\u0438\u0442\u0441\u044f \u043d\u0430 noexec-\u0440\u0430\u0437\u0434\u0435\u043b\u0435: \u0431\u0438\u043d\u0430\u0440\u043d\u044b\u0435 \u0444\u0430\u0439\u043b\u044b \u0442\u0430\u043c \u043d\u0435 \u0437\u0430\u043f\u0443\u0441\u0442\u044f\u0442\u0441\u044f, \u0432\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u0434\u0440\u0443\u0433\u043e\u0439 --home'
        's_fw' = '\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0430 \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u0430'
        's_boot' = '\u041f\u043e\u0434\u0433\u043e\u0442\u043e\u0432\u043a\u0430 \u043f\u0430\u043d\u0435\u043b\u0438 (\u0443\u0447\u0451\u0442\u043d\u0430\u044f \u0437\u0430\u043f\u0438\u0441\u044c \u0430\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430, \u0437\u0430\u0449\u0438\u0449\u0451\u043d\u043d\u044b\u0439 \u043f\u0443\u0442\u044c)'
        's_start' = '\u0417\u0430\u043f\u0443\u0441\u043a \u0441\u043b\u0443\u0436\u0431'
        's_health' = '\u041e\u0436\u0438\u0434\u0430\u043d\u0438\u0435 \u0433\u043e\u0442\u043e\u0432\u043d\u043e\u0441\u0442\u0438 \u0441\u043b\u0443\u0436\u0431'
        's_backup' = '\u0420\u0435\u0437\u0435\u0440\u0432\u043d\u043e\u0435 \u043a\u043e\u043f\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u0435 \u043d\u0430\u0441\u0442\u0440\u043e\u0435\u043a \u0438 \u0434\u0430\u043d\u043d\u044b\u0445'
        'w_rollback' = '\u041d\u043e\u0432\u0430\u044f \u0432\u0435\u0440\u0441\u0438\u044f \u043d\u0435 \u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442: \u043e\u0442\u043a\u0430\u0442 \u043a \u043f\u0440\u0435\u0434\u044b\u0434\u0443\u0449\u0435\u0439'
        'up_to_date' = '\u0423\u0436\u0435 \u0430\u043a\u0442\u0443\u0430\u043b\u044c\u043d\u043e ({0})'
        'not_installed' = 'ToutWAF \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d: \u043e\u0431\u043d\u043e\u0432\u043b\u044f\u0442\u044c \u043d\u0435\u0447\u0435\u0433\u043e.'
        'st_channel' = '\u041a\u0430\u043d\u0430\u043b: {0}'
        'st_latest' = '\u041f\u043e\u0441\u043b\u0435\u0434\u043d\u044f\u044f \u0434\u043e\u0441\u0442\u0443\u043f\u043d\u0430\u044f \u0432\u0435\u0440\u0441\u0438\u044f: {0}'
        'st_newer' = '\u0434\u043e\u0441\u0442\u0443\u043f\u043d\u043e \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435: \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0441 --update'
        'e_yanked' = '\u0412\u0435\u0440\u0441\u0438\u044f {0} \u043e\u0442\u043e\u0437\u0432\u0430\u043d\u0430 (yanked) \u0438 \u043d\u0435 \u0434\u043e\u043b\u0436\u043d\u0430 \u0443\u0441\u0442\u0430\u043d\u0430\u0432\u043b\u0438\u0432\u0430\u0442\u044c\u0441\u044f. \u0417\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 --update \u0434\u043b\u044f \u0430\u043a\u0442\u0443\u0430\u043b\u044c\u043d\u043e\u0439 \u0432\u0435\u0440\u0441\u0438\u0438 \u0438\u043b\u0438 --force, \u0447\u0442\u043e\u0431\u044b \u043e\u0431\u043e\u0439\u0442\u0438.'
        'e_nover' = '\u0412 \u043a\u0430\u043d\u0430\u043b\u0435 {0} \u043f\u043e\u043a\u0430 \u043d\u0435 \u043e\u043f\u0443\u0431\u043b\u0438\u043a\u043e\u0432\u0430\u043d\u043e \u043d\u0438 \u043e\u0434\u043d\u043e\u0439 \u0432\u0435\u0440\u0441\u0438\u0438, \u0443\u0441\u0442\u0430\u043d\u0430\u0432\u043b\u0438\u0432\u0430\u0442\u044c \u043d\u0435\u0447\u0435\u0433\u043e. ToutWAF \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d \u0438 \u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u0451\u043d. \u0427\u0442\u043e\u0431\u044b \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c \u0438\u0437 \u043a\u0430\u043d\u0430\u043b\u0430 {1}, \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430 \u0441 -Channel {2}.'
        'e_installer_old' = '\u042d\u0442\u043e\u0442 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043b\u0438\u0448\u043a\u043e\u043c \u0441\u0442\u0430\u0440\u044b\u0439 \u0434\u043b\u044f \u044d\u0442\u043e\u0433\u043e \u0440\u0435\u043b\u0438\u0437\u0430 (\u043d\u0443\u0436\u043d\u0430 \u0432\u0435\u0440\u0441\u0438\u044f {0}): \u0441\u043a\u0430\u0447\u0430\u0439\u0442\u0435 \u0435\u0433\u043e \u0437\u0430\u043d\u043e\u0432\u043e \u043f\u043e URL \u043a\u0430\u043d\u0430\u043b\u0430.'
        'up_rebuilt' = '\u0422\u0430 \u0436\u0435 \u0432\u0435\u0440\u0441\u0438\u044f, \u043d\u043e\u0432\u0430\u044f \u0441\u0431\u043e\u0440\u043a\u0430: \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0430 {0}, \u0434\u043e\u0441\u0442\u0443\u043f\u043d\u0430 {1}. \u0412\u044b\u043f\u043e\u043b\u043d\u044f\u0435\u0442\u0441\u044f \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435.'
        'st_newbuild' = '\u0442\u0430 \u0436\u0435 \u0432\u0435\u0440\u0441\u0438\u044f, \u0434\u043e\u0441\u0442\u0443\u043f\u043d\u0430 \u043d\u043e\u0432\u0430\u044f \u0441\u0431\u043e\u0440\u043a\u0430: \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0441\u043d\u043e\u0432\u0430 \u0441 {0}'
        'st_nochannel' = '\u041f\u043e\u0441\u043b\u0435\u0434\u043d\u044f\u044f \u0434\u043e\u0441\u0442\u0443\u043f\u043d\u0430\u044f \u0432\u0435\u0440\u0441\u0438\u044f: \u0432 \u044d\u0442\u043e\u043c \u043a\u0430\u043d\u0430\u043b\u0435 \u043f\u043e\u043a\u0430 \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u043e\u043f\u0443\u0431\u043b\u0438\u043a\u043e\u0432\u0430\u043d\u043e'
        'w_mirror' = '\u041f\u0443\u0431\u043b\u0438\u0447\u043d\u043e\u0435 \u0437\u0435\u0440\u043a\u0430\u043b\u043e \u043e\u0442\u0434\u0430\u043b\u043e \u0444\u0430\u0439\u043b\u044b, \u043a\u043e\u0442\u043e\u0440\u044b\u0435 \u043d\u0435 \u0441\u043e\u0433\u043b\u0430\u0441\u0443\u044e\u0442\u0441\u044f \u043c\u0435\u0436\u0434\u0443 \u0441\u043e\u0431\u043e\u0439 ({0}): \u0432\u0435\u0440\u043e\u044f\u0442\u043d\u043e, \u043e\u043d\u043e \u0435\u0449\u0451 \u043e\u0431\u043d\u043e\u0432\u043b\u044f\u0435\u0442\u0441\u044f \u043f\u043e\u0441\u043b\u0435 \u043f\u0443\u0431\u043b\u0438\u043a\u0430\u0446\u0438\u0438. \u041a\u0430\u043d\u0430\u043b \u0431\u0443\u0434\u0435\u0442 \u043f\u0440\u043e\u0447\u0438\u0442\u0430\u043d \u0437\u0430\u043d\u043e\u0432\u043e \u043e\u0434\u0438\u043d \u0440\u0430\u0437.'
        'e_mismatch' = '\u043a\u043e\u043d\u0442\u0440\u043e\u043b\u044c\u043d\u0430\u044f \u0441\u0443\u043c\u043c\u0430 \u043d\u0435 \u0441\u043e\u0432\u043f\u0430\u0434\u0430\u0435\u0442 \u0434\u043b\u044f {0} ({1}): \u0437\u0430\u0433\u0440\u0443\u0436\u0435\u043d\u043d\u044b\u0439 \u0444\u0430\u0439\u043b \u043d\u0435 \u0441\u043e\u043e\u0442\u0432\u0435\u0442\u0441\u0442\u0432\u0443\u0435\u0442 \u043e\u043f\u0443\u0431\u043b\u0438\u043a\u043e\u0432\u0430\u043d\u043d\u043e\u0439 \u0441\u0443\u043c\u043c\u0435, \u043f\u043e\u044d\u0442\u043e\u043c\u0443 \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e \u0438 \u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u043e. \u0421\u0440\u0430\u0437\u0443 \u043f\u043e\u0441\u043b\u0435 \u043f\u0443\u0431\u043b\u0438\u043a\u0430\u0446\u0438\u0438 \u043f\u0443\u0431\u043b\u0438\u0447\u043d\u043e\u0435 \u0437\u0435\u0440\u043a\u0430\u043b\u043e \u043c\u043e\u0436\u0435\u0442 \u043d\u0435\u0441\u043a\u043e\u043b\u044c\u043a\u043e \u043c\u0438\u043d\u0443\u0442 \u043e\u0442\u0434\u0430\u0432\u0430\u0442\u044c \u043f\u0440\u0435\u0436\u043d\u0438\u0435 \u0444\u0430\u0439\u043b\u044b: \u043f\u043e\u0434\u043e\u0436\u0434\u0438\u0442\u0435 \u043f\u044f\u0442\u044c \u043c\u0438\u043d\u0443\u0442 \u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430. \u0415\u0441\u043b\u0438 \u043e\u0448\u0438\u0431\u043a\u0430 \u043f\u043e\u0432\u0442\u043e\u0440\u0438\u0442\u0441\u044f, \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u0430\u0432\u043b\u0438\u0432\u0430\u0439\u0442\u0435: \u043f\u0443\u0431\u043b\u0438\u043a\u0430\u0446\u0438\u044f \u043f\u043e\u0432\u0440\u0435\u0436\u0434\u0435\u043d\u0430.'
        'e_downgrade' = '\u041f\u043e\u0441\u043b\u0435\u0434\u043d\u0438\u0439 \u0440\u0435\u043b\u0438\u0437 {0} \u043a\u0430\u043d\u0430\u043b\u0430 {1} \u0441\u0442\u0430\u0440\u0448\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043d\u043e\u0433\u043e {2}: \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0439\u0442\u0435 --force \u0434\u043b\u044f \u043f\u043e\u043d\u0438\u0436\u0435\u043d\u0438\u044f \u0432\u0435\u0440\u0441\u0438\u0438.'
        's_sigok' = '\u043f\u043e\u0434\u043f\u0438\u0441\u044c \u0440\u0435\u043b\u0438\u0437\u0430 \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u0430, \u043a\u043b\u044e\u0447 {0}'
        'w_sigold' = '\u0432\u0435\u0440\u0441\u0438\u044f {0} \u043e\u043f\u0443\u0431\u043b\u0438\u043a\u043e\u0432\u0430\u043d\u0430 \u0431\u0435\u0437 \u043f\u043e\u0434\u043f\u0438\u0441\u0438 (\u0432\u0435\u0440\u0441\u0438\u0438 \u0434\u043e 0.2.0-dev.7 \u043d\u0435 \u043f\u043e\u0434\u043f\u0438\u0441\u0430\u043d\u044b): \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u0430 \u0442\u043e\u043b\u044c\u043a\u043e SHA-256, \u043f\u043e\u0434\u043f\u0438\u0441\u044c \u043f\u0440\u043e\u0432\u0435\u0440\u0438\u0442\u044c \u043d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c'
        'w_sigskip' = '\u043f\u043e\u0434\u043f\u0438\u0441\u044c \u0440\u0435\u043b\u0438\u0437\u0430 \u041d\u0415 \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u0430: openssl.exe \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d \u0432 PATH (\u0432 Windows \u043d\u0435\u0442 \u0432\u0441\u0442\u0440\u043e\u0435\u043d\u043d\u043e\u0439 \u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0438 Ed25519), \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u0430 \u0442\u043e\u043b\u044c\u043a\u043e SHA-256. \u0423\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0435 OpenSSL 3 \u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0441\u043d\u043e\u0432\u0430, \u0447\u0442\u043e\u0431\u044b \u043f\u0440\u043e\u0432\u0435\u0440\u0438\u0442\u044c \u043f\u043e \u043a\u043b\u044e\u0447\u0443 {0}'
        'done' = '\u0413\u043e\u0442\u043e\u0432\u043e.'
        'failed' = '\u041e\u0448\u0438\u0431\u043a\u0430'
        'log_hint' = '\u041f\u043e\u043b\u043d\u044b\u0439 \u0436\u0443\u0440\u043d\u0430\u043b: {0}'
        'dry_done' = '\u041f\u0440\u043e\u0431\u043d\u044b\u0439 \u0437\u0430\u043f\u0443\u0441\u043a: \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u043e.'
        'sum_title' = '\u0418\u0442\u043e\u0433\u0438 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438'
        'sum_panel' = '\u0421\u0441\u044b\u043b\u043a\u0438 \u043d\u0430 \u043f\u0430\u043d\u0435\u043b\u044c'
        'sum_tls_note' = '\u0422\u043e\u043b\u044c\u043a\u043e HTTPS. \u0421\u0435\u0440\u0442\u0438\u0444\u0438\u043a\u0430\u0442 \u0441\u0430\u043c\u043e\u043f\u043e\u0434\u043f\u0438\u0441\u0430\u043d\u043d\u044b\u0439, \u043f\u043e\u043a\u0430 \u0432\u044b \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0435 \u0441\u0432\u043e\u0439: \u0431\u0440\u0430\u0443\u0437\u0435\u0440 \u043f\u043e\u043a\u0430\u0436\u0435\u0442 \u043f\u0440\u0435\u0434\u0443\u043f\u0440\u0435\u0436\u0434\u0435\u043d\u0438\u0435.'
        'sum_local' = '\u041b\u043e\u043a\u0430\u043b\u044c\u043d\u044b\u0435 \u0430\u0434\u0440\u0435\u0441\u0430'
        'sum_public' = '\u041f\u0443\u0431\u043b\u0438\u0447\u043d\u044b\u0439 \u0430\u0434\u0440\u0435\u0441'
        'sum_public_unknown' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043e\u043f\u0440\u0435\u0434\u0435\u043b\u0438\u0442\u044c \u043f\u0443\u0431\u043b\u0438\u0447\u043d\u044b\u0439 IP (\u043d\u0435\u0442 \u0441\u0435\u0442\u0438 \u0438\u043b\u0438 \u0431\u043b\u043e\u043a\u0438\u0440\u043e\u0432\u043a\u0430). \u0418\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0439\u0442\u0435 \u043f\u0443\u0431\u043b\u0438\u0447\u043d\u044b\u0439 IP \u0438\u043b\u0438 DNS-\u0438\u043c\u044f \u0441\u0435\u0440\u0432\u0435\u0440\u0430 \u0432\u043c\u0435\u0441\u0442\u043e \u043b\u043e\u043a\u0430\u043b\u044c\u043d\u044b\u0445 \u0430\u0434\u0440\u0435\u0441\u043e\u0432 \u0438\u043b\u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0441\u043d\u043e\u0432\u0430 \u0441 --public-host.'
        'sum_admin' = '\u0423\u0447\u0451\u0442\u043d\u0430\u044f \u0437\u0430\u043f\u0438\u0441\u044c \u0430\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430'
        'sum_user' = '\u0418\u043c\u044f \u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044f'
        'sum_password' = '\u041f\u0430\u0440\u043e\u043b\u044c'
        'sum_pw_once' = '\u043f\u043e\u043a\u0430\u0437\u044b\u0432\u0430\u0435\u0442\u0441\u044f \u0422\u041e\u041b\u042c\u041a\u041e \u041e\u0414\u0418\u041d \u0440\u0430\u0437 - \u0438\u0437\u043c\u0435\u043d\u0438\u0442\u0435 \u0432 \u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438 > \u0414\u043e\u0441\u0442\u0443\u043f / \u0410\u043a\u043a\u0430\u0443\u043d\u0442'
        'sum_pw_unchanged' = '\u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u0451\u043d (\u043d\u0438\u043a\u043e\u0433\u0434\u0430 \u043d\u0435 \u0433\u0435\u043d\u0435\u0440\u0438\u0440\u0443\u0435\u0442\u0441\u044f \u0437\u0430\u043d\u043e\u0432\u043e). \u0421\u0431\u0440\u043e\u0441: toutwaf-cp admin reset-password --user {0}'
        'sum_setup' = '\u041e\u0434\u043d\u043e\u0440\u0430\u0437\u043e\u0432\u0430\u044f \u0441\u0441\u044b\u043b\u043a\u0430 \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438'
        'sum_setup_note' = '\u041e\u0442\u043a\u0440\u043e\u0439\u0442\u0435 \u0435\u0451, \u0447\u0442\u043e\u0431\u044b \u043d\u0430\u0441\u0442\u0440\u043e\u0438\u0442\u044c \u0441\u0441\u044b\u043b\u043a\u0443 \u043f\u0430\u043d\u0435\u043b\u0438, \u0443\u0447\u0451\u0442\u043d\u0443\u044e \u0437\u0430\u043f\u0438\u0441\u044c \u0438 \u043f\u0430\u0440\u043e\u043b\u044c \u0432 \u0432\u0435\u0431-\u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a\u0435.'
        'p_dpapi_warn' = '\u041f\u043e\u0440\u0442 9444 (API data plane) \u041d\u0415 \u043e\u0442\u043a\u0440\u044b\u0442: \u0440\u0430\u0437\u0440\u0435\u0448\u0430\u0439\u0442\u0435 \u0435\u0433\u043e \u0442\u043e\u043b\u044c\u043a\u043e \u0441 \u0432\u0430\u0448\u0438\u0445 \u0443\u0437\u043b\u043e\u0432 data plane'
        'p_dpapi_only' = '9444/tcp \u0442\u043e\u043b\u044c\u043a\u043e \u0441 \u0432\u0430\u0448\u0438\u0445 data plane, \u043d\u0430\u043f\u0440\u0438\u043c\u0435\u0440:'
        'sum_setup_none' = '\u0421\u0441\u044b\u043b\u043a\u0438 \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438 \u0441\u0435\u0439\u0447\u0430\u0441 \u043d\u0435\u0442 (\u0443\u0436\u0435 \u0432\u044b\u0434\u0430\u043d\u0430 \u0438\u043b\u0438 \u0443\u0447\u0451\u0442\u043d\u0430\u044f \u0437\u0430\u043f\u0438\u0441\u044c \u0443\u0436\u0435 \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u043e\u0432\u0430\u043b\u0430). \u0421\u043e\u0437\u0434\u0430\u0442\u044c \u043d\u043e\u0432\u0443\u044e: toutwaf-cp setup-link --regenerate'
        'sum_ports' = '\u041f\u043e\u0440\u0442\u044b \u0434\u043b\u044f \u043e\u0442\u043a\u0440\u044b\u0442\u0438\u044f \u0432 \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u0435'
        'sum_cmds' = '\u041a\u043e\u043c\u0430\u043d\u0434\u044b'
        'sum_cloud' = '\u041e\u0431\u043b\u0430\u043a\u043e / \u0445\u043e\u0441\u0442\u0438\u043d\u0433: \u043e\u0442\u043a\u0440\u043e\u0439\u0442\u0435 \u044d\u0442\u0438 \u043f\u043e\u0440\u0442\u044b \u0442\u0430\u043a\u0436\u0435 \u0432 \u0433\u0440\u0443\u043f\u043f\u0435 \u0431\u0435\u0437\u043e\u043f\u0430\u0441\u043d\u043e\u0441\u0442\u0438 / \u0441\u0435\u0442\u0435\u0432\u043e\u043c ACL \u043f\u0440\u043e\u0432\u0430\u0439\u0434\u0435\u0440\u0430.'
        'sum_file' = '\u0418\u0442\u043e\u0433\u0438 \u0441\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u044b (\u0442\u043e\u043b\u044c\u043a\u043e root): {0}'
        'sum_fallback' = '\u0423 \u044d\u0442\u043e\u0433\u043e control plane \u043f\u043e\u043a\u0430 \u043d\u0435\u0442 \u043a\u043e\u043c\u0430\u043d\u0434\u044b ''bootstrap'': \u043e\u0442\u043a\u0440\u043e\u0439\u0442\u0435 URL \u043a\u043e\u043d\u0441\u043e\u043b\u0438 \u0438 \u0441\u043b\u0435\u0434\u0443\u0439\u0442\u0435 \u0441\u0442\u0440\u0430\u043d\u0438\u0446\u0435 \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438.'
        'sum_node_hint' = '\u0427\u0442\u043e\u0431\u044b \u0443\u043f\u0440\u0430\u0432\u043b\u044f\u0442\u044c \u044d\u0442\u0438\u043c \u0443\u0437\u043b\u043e\u043c \u0438\u0437 \u043a\u043e\u043d\u0441\u043e\u043b\u0438: \u0423\u0437\u043b\u044b > \u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c \u0443\u0437\u0435\u043b, \u0437\u0430\u0442\u0435\u043c \u0437\u0430\u0434\u0430\u0439\u0442\u0435 control_plane.url / enroll_token \u0432 {0}.'
        'q_fwmodule' = '\u0425\u043e\u0442\u0438\u0442\u0435, \u0447\u0442\u043e\u0431\u044b ToutWAF \u0442\u0430\u043a\u0436\u0435 \u0443\u043f\u0440\u0430\u0432\u043b\u044f\u043b \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u043e\u043c \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u044b?'
        'fwmod_n1' = '\u041d\u0435\u043e\u0431\u044f\u0437\u0430\u0442\u0435\u043b\u044c\u043d\u044b\u0439 \u043c\u043e\u0434\u0443\u043b\u044c, \u0432\u044b\u043a\u043b\u044e\u0447\u0435\u043d, \u0435\u0441\u043b\u0438 \u0432\u044b \u043d\u0435 \u043e\u0442\u0432\u0435\u0442\u0438\u0442\u0435 \u00ab\u0434\u0430\u00bb. \u0412\u043e \u0432\u0440\u0435\u043c\u044f \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438 \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u043f\u0440\u0438\u043c\u0435\u043d\u044f\u0435\u0442\u0441\u044f: \u043a\u0430\u0436\u0434\u043e\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435 \u0432\u044b \u043f\u0440\u043e\u0432\u0435\u0440\u044f\u0435\u0442\u0435 \u0432 \u043a\u043e\u043d\u0441\u043e\u043b\u0438.'
        's_bkclient' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u043a\u043b\u0438\u0435\u043d\u0442\u0430 ToutWAF Backup (\u043f\u043e\u0434\u043f\u0438\u0441\u044c \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u0430)'
        'bkc_done' = '\u041a\u043b\u0438\u0435\u043d\u0442 ToutWAF Backup \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d. \u0414\u0430\u043b\u0435\u0435: \u043a\u043e\u043d\u0441\u043e\u043b\u044c, \u0420\u0435\u0437\u0435\u0440\u0432\u043d\u044b\u0435 \u043a\u043e\u043f\u0438\u0438 > \u0421\u0435\u0440\u0432\u0435\u0440\u044b \u043a\u043e\u043f\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u044f, \u0447\u0442\u043e\u0431\u044b \u043f\u0440\u0438\u0432\u044f\u0437\u0430\u0442\u044c \u0441\u0435\u0440\u0432\u0435\u0440.'
        'bkc_fail' = '\u041a\u043b\u0438\u0435\u043d\u0442 ToutWAF Backup \u041d\u0415 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d ({0}). \u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u0442\u0441\u044f; \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0435 \u0435\u0433\u043e \u043f\u043e\u0437\u0436\u0435 \u0441 --with-backup-client.'
        'bkc_nokey' = '\u041a\u043b\u0438\u0435\u043d\u0442 ToutWAF Backup \u041d\u0415 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d: \u043d\u0435\u0442 \u043e\u0442\u043a\u0440\u044b\u0442\u043e\u0433\u043e \u043a\u043b\u044e\u0447\u0430 \u0440\u0435\u043b\u0438\u0437\u0430. \u0423\u043a\u0430\u0436\u0438\u0442\u0435 \u0435\u0433\u043e \u0447\u0435\u0440\u0435\u0437 --backup-client-pubkey (\u0438\u043b\u0438 TOUTWAF_BACKUP_PUBKEY, \u0438\u043b\u0438 \u0444\u0430\u0439\u043b backup-release.pub \u0432 \u043a\u0430\u0442\u0430\u043b\u043e\u0433\u0435 \u043a\u043e\u043d\u0444\u0438\u0433\u0443\u0440\u0430\u0446\u0438\u0438); \u0431\u0435\u0437 \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u043d\u043e\u0439 \u043f\u043e\u0434\u043f\u0438\u0441\u0438 \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u0430\u0432\u043b\u0438\u0432\u0430\u0435\u0442\u0441\u044f.'
        'bkc_badsig' = '\u041a\u043b\u0438\u0435\u043d\u0442 ToutWAF Backup \u041d\u0415 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d: \u043f\u043e\u0434\u043f\u0438\u0441\u044c \u0440\u0435\u043b\u0438\u0437\u0430 \u041d\u0415\u0414\u0415\u0419\u0421\u0422\u0412\u0418\u0422\u0415\u041b\u042c\u041d\u0410. \u041d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e.'
        'tele_on' = '\u0422\u0435\u043b\u0435\u043c\u0435\u0442\u0440\u0438\u044f: \u043f\u043e \u0443\u043c\u043e\u043b\u0447\u0430\u043d\u0438\u044e ToutWAF \u043f\u0435\u0440\u0435\u0434\u0430\u0451\u0442 \u043f\u0440\u043e\u0441\u0442\u0440\u0430\u043d\u0441\u0442\u0432\u0443 \u0438\u0437\u0434\u0430\u0442\u0435\u043b\u044f (app.toutwaf.com) \u0437\u0430\u0431\u043b\u043e\u043a\u0438\u0440\u043e\u0432\u0430\u043d\u043d\u044b\u0435 \u0430\u0442\u0430\u043a\u0438 (\u0430\u0434\u0440\u0435\u0441 \u0430\u0442\u0430\u043a\u0443\u044e\u0449\u0435\u0433\u043e, \u0441\u0442\u0440\u0430\u043d\u0430, \u0442\u0438\u043f \u0430\u0442\u0430\u043a\u0438, \u043f\u0440\u0430\u0432\u0438\u043b\u043e), \u0430\u0433\u0440\u0435\u0433\u0438\u0440\u043e\u0432\u0430\u043d\u043d\u044b\u0435 \u0446\u0438\u0444\u0440\u044b \u0438 \u0438\u043c\u0435\u043d\u0430 \u0445\u043e\u0441\u0442\u043e\u0432 \u0437\u0430\u0449\u0438\u0449\u0430\u0435\u043c\u044b\u0445 \u0441\u0430\u0439\u0442\u043e\u0432. \u041d\u0438\u043a\u043e\u0433\u0434\u0430 \u0441\u043e\u0434\u0435\u0440\u0436\u0438\u043c\u043e\u0435 \u0437\u0430\u043f\u0440\u043e\u0441\u043e\u0432 \u0438 \u043d\u0438\u043a\u043e\u0433\u0434\u0430 \u0437\u0430\u043a\u043e\u043d\u043d\u044b\u0445 \u043f\u043e\u0441\u0435\u0442\u0438\u0442\u0435\u043b\u0435\u0439. \u041e\u0442\u043a\u043b\u044e\u0447\u0430\u0435\u0442\u0441\u044f \u043e\u0434\u043d\u0438\u043c \u0449\u0435\u043b\u0447\u043a\u043e\u043c \u0432 \u043a\u043e\u043d\u0441\u043e\u043b\u0438 (\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438, \u041a\u043e\u043d\u0444\u0438\u0434\u0435\u043d\u0446\u0438\u0430\u043b\u044c\u043d\u043e\u0441\u0442\u044c \u0438 \u0442\u0435\u043b\u0435\u043c\u0435\u0442\u0440\u0438\u044f), \u043b\u0438\u0431\u043e \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0435 \u0441 --no-telemetry (\u0438\u043b\u0438 TOUTWAF_TELEMETRY=0) \u0434\u043b\u044f \u043d\u0443\u043b\u0435\u0432\u043e\u0439 \u0442\u0435\u043b\u0435\u043c\u0435\u0442\u0440\u0438\u0438. \u041f\u043e\u0434\u0440\u043e\u0431\u043d\u043e\u0441\u0442\u0438: docs/confidentialite-telemetrie.md'
        'tele_off' = '\u0422\u0435\u043b\u0435\u043c\u0435\u0442\u0440\u0438\u044f: \u0437\u0430\u043f\u0440\u043e\u0448\u0435\u043d\u0430 \u043d\u0443\u043b\u0435\u0432\u0430\u044f \u0442\u0435\u043b\u0435\u043c\u0435\u0442\u0440\u0438\u044f (--no-telemetry / TOUTWAF_TELEMETRY=0). \u041d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0431\u0443\u0434\u0435\u0442 \u043e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043e \u0432 \u043f\u0440\u043e\u0441\u0442\u0440\u0430\u043d\u0441\u0442\u0432\u043e \u0438\u0437\u0434\u0430\u0442\u0435\u043b\u044f \u0438 \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0431\u0443\u0434\u0435\u0442 \u043f\u043e\u043b\u0443\u0447\u0435\u043d\u043e \u043e\u0442 \u043d\u0435\u0433\u043e; \u043a\u043e\u043d\u0441\u043e\u043b\u044c \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0441\u044f \u0441 \u0432\u043a\u043b\u044e\u0447\u0451\u043d\u043d\u044b\u043c \u043f\u0435\u0440\u0435\u043a\u043b\u044e\u0447\u0430\u0442\u0435\u043b\u0435\u043c \u00ab\u041d\u0443\u043b\u0435\u0432\u0430\u044f \u0442\u0435\u043b\u0435\u043c\u0435\u0442\u0440\u0438\u044f\u00bb. \u041f\u043e\u0437\u0436\u0435 \u044d\u0442\u043e \u043c\u043e\u0436\u043d\u043e \u0438\u0437\u043c\u0435\u043d\u0438\u0442\u044c \u0432 \u043a\u043e\u043d\u0441\u043e\u043b\u0438 (\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438, \u041a\u043e\u043d\u0444\u0438\u0434\u0435\u043d\u0446\u0438\u0430\u043b\u044c\u043d\u043e\u0441\u0442\u044c \u0438 \u0442\u0435\u043b\u0435\u043c\u0435\u0442\u0440\u0438\u044f).'
        'fwmod_n2' = '\u041a\u0430\u0436\u0434\u043e\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435 \u043f\u0440\u043e\u0445\u043e\u0434\u0438\u0442 \u043f\u0440\u043e\u0431\u043d\u044b\u0439 \u043f\u0435\u0440\u0438\u043e\u0434 \u0441 \u043e\u0431\u0440\u0430\u0442\u043d\u044b\u043c \u043e\u0442\u0441\u0447\u0451\u0442\u043e\u043c \u0438 \u043e\u0442\u043a\u0430\u0442\u044b\u0432\u0430\u0435\u0442\u0441\u044f \u0441\u0430\u043c\u043e, \u0435\u0441\u043b\u0438 \u0432\u044b \u0435\u0433\u043e \u043d\u0435 \u0441\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u0435; \u0437\u0430\u0449\u0438\u0442\u0430 \u043e\u0442 \u0431\u043b\u043e\u043a\u0438\u0440\u043e\u0432\u043a\u0438 \u043e\u0442\u043a\u043b\u043e\u043d\u044f\u0435\u0442 \u043b\u044e\u0431\u043e\u0435 \u043f\u0440\u0430\u0432\u0438\u043b\u043e, \u043a\u043e\u0442\u043e\u0440\u043e\u0435 \u043e\u0442\u0440\u0435\u0437\u0430\u043b\u043e \u0431\u044b SSH \u0438\u043b\u0438 \u043a\u043e\u043d\u0441\u043e\u043b\u044c.'
        'fwmod_n3' = '\u042d\u0442\u043e \u043d\u0435 \u043f\u0440\u0435\u0434\u044b\u0434\u0443\u0449\u0438\u0439 \u0432\u043e\u043f\u0440\u043e\u0441, \u043a\u043e\u0442\u043e\u0440\u044b\u0439 \u043b\u0438\u0448\u044c \u043e\u0442\u043a\u0440\u044b\u0432\u0430\u0435\u0442 \u043d\u0443\u0436\u043d\u044b\u0435 ToutWAF \u043f\u043e\u0440\u0442\u044b \u0432 \u0441\u0438\u0441\u0442\u0435\u043c\u043d\u043e\u043c \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u0435 (--no-firewall).'
        's_fwmod' = '\u0412\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0435 \u043c\u043e\u0434\u0443\u043b\u044f \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u0430 (\u043f\u0440\u0430\u0432\u0438\u043b\u0430 \u043d\u0435 \u043f\u0440\u0438\u043c\u0435\u043d\u044f\u044e\u0442\u0441\u044f)'
        'fwmod_done' = '\u041c\u043e\u0434\u0443\u043b\u044c \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u0430 \u0432\u043a\u043b\u044e\u0447\u0451\u043d. \u041d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u043f\u0440\u0438\u043c\u0435\u043d\u0435\u043d\u043e: \u043e\u0442\u043a\u0440\u043e\u0439\u0442\u0435 \u00ab\u0411\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u00bb \u0432 \u043a\u043e\u043d\u0441\u043e\u043b\u0438, \u0447\u0442\u043e\u0431\u044b \u043f\u0440\u043e\u0432\u0435\u0440\u0438\u0442\u044c \u0438 \u043e\u043f\u0440\u043e\u0431\u043e\u0432\u0430\u0442\u044c \u043f\u0440\u0430\u0432\u0438\u043b\u0430.'
        'fwmod_fail' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0432\u043a\u043b\u044e\u0447\u0438\u0442\u044c \u043c\u043e\u0434\u0443\u043b\u044c \u0431\u0440\u0430\u043d\u0434\u043c\u0430\u0443\u044d\u0440\u0430 ({0}). \u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u0442\u0441\u044f; \u0432\u043a\u043b\u044e\u0447\u0438\u0442\u0435 \u0435\u0433\u043e \u043f\u043e\u0437\u0436\u0435 \u0432 \u00ab\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438 > \u041c\u043e\u0434\u0443\u043b\u0438\u00bb.'
        's_link' = '\u041f\u0440\u0438\u0432\u044f\u0437\u043a\u0430 \u043f\u043b\u043e\u0441\u043a\u043e\u0441\u0442\u0438 \u0434\u0430\u043d\u043d\u044b\u0445 \u043a \u043a\u043e\u043d\u0441\u043e\u043b\u0438'
        'dp_link_ok' = '\u041f\u043b\u043e\u0441\u043a\u043e\u0441\u0442\u044c \u0434\u0430\u043d\u043d\u044b\u0445 \u0430\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u0438 \u043f\u0440\u0438\u0432\u044f\u0437\u0430\u043d\u0430 \u043a \u043a\u043e\u043d\u0441\u043e\u043b\u0438: \u0432\u0440\u0443\u0447\u043d\u0443\u044e \u043d\u0430\u0441\u0442\u0440\u0430\u0438\u0432\u0430\u0442\u044c \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u043d\u0443\u0436\u043d\u043e.'
        'dp_link_same' = '\u041f\u043b\u043e\u0441\u043a\u043e\u0441\u0442\u044c \u0434\u0430\u043d\u043d\u044b\u0445 \u0443\u0436\u0435 \u043f\u0440\u0438\u0432\u044f\u0437\u0430\u043d\u0430 \u043a \u043a\u043e\u043d\u0441\u043e\u043b\u0438; \u0435\u0451 \u043a\u043e\u043d\u0444\u0438\u0433\u0443\u0440\u0430\u0446\u0438\u044f \u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0430.'
        'dp_link_fixed' = '\u041a\u043e\u043d\u0444\u0438\u0433\u0443\u0440\u0430\u0446\u0438\u044f \u043f\u043b\u043e\u0441\u043a\u043e\u0441\u0442\u0438 \u0434\u0430\u043d\u043d\u044b\u0445 \u0438\u0441\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u0430 (\u0434\u0443\u0431\u043b\u0438\u0440\u0443\u044e\u0449\u0438\u0435\u0441\u044f \u0431\u043b\u043e\u043a\u0438 control_plane \u043e\u0431\u044a\u0435\u0434\u0438\u043d\u0435\u043d\u044b); \u043f\u0440\u0435\u0436\u043d\u0438\u0439 \u0444\u0430\u0439\u043b \u0441\u043e\u0445\u0440\u0430\u043d\u0451\u043d.'
        'dp_link_remote' = '\u041f\u043b\u043e\u0441\u043a\u043e\u0441\u0442\u044c \u0434\u0430\u043d\u043d\u044b\u0445 \u043d\u0430 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435 \u043d\u0430\u0441\u0442\u0440\u043e\u0435\u043d\u0430 \u043d\u0430 \u0434\u0440\u0443\u0433\u0443\u044e \u043a\u043e\u043d\u0441\u043e\u043b\u044c; \u043e\u043d\u0430 \u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0430.'
        'dp_link_fail' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0430\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u0438 \u043f\u0440\u0438\u0432\u044f\u0437\u0430\u0442\u044c \u043f\u043b\u043e\u0441\u043a\u043e\u0441\u0442\u044c \u0434\u0430\u043d\u043d\u044b\u0445 \u043a \u043a\u043e\u043d\u0441\u043e\u043b\u0438: {0}'
        'dp_link_fail_hint' = '\u041f\u043b\u043e\u0441\u043a\u043e\u0441\u0442\u044c \u0434\u0430\u043d\u043d\u044b\u0445 \u0441\u043e\u0445\u0440\u0430\u043d\u044f\u0435\u0442 \u0430\u0432\u0442\u043e\u043d\u043e\u043c\u043d\u0443\u044e \u043a\u043e\u043d\u0444\u0438\u0433\u0443\u0440\u0430\u0446\u0438\u044e, \u043f\u043e\u044d\u0442\u043e\u043c\u0443 \u0441\u0430\u0439\u0442\u044b \u043e\u0442\u0432\u0435\u0447\u0430\u044e\u0442 HTTP 421, \u043f\u043e\u043a\u0430 \u043e\u043d\u0430 \u043d\u0435 \u043f\u0440\u0438\u0432\u044f\u0437\u0430\u043d\u0430. \u0423\u0441\u0442\u0440\u0430\u043d\u0438\u0442\u0435 \u043f\u0440\u0438\u0447\u0438\u043d\u0443 \u0432\u044b\u0448\u0435 \u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430: \u043e\u043d \u043f\u0440\u0438\u0432\u044f\u0436\u0435\u0442 \u0443\u0437\u0435\u043b \u0441\u0430\u043c.'
        'st_title' = '\u0421\u043e\u0441\u0442\u043e\u044f\u043d\u0438\u0435'
        'st_healthy' = '\u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442'
        'st_unhealthy' = '\u041d\u0415 \u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442'
        'st_active' = '\u0430\u043a\u0442\u0438\u0432\u043d\u0430'
        'st_inactive' = '\u043d\u0435 \u0430\u043a\u0442\u0438\u0432\u043d\u0430'
        'st_listening' = '\u0441\u043b\u0443\u0448\u0430\u0435\u0442'
        'st_closed' = '\u043d\u0435 \u0441\u043b\u0443\u0448\u0430\u0435\u0442'
        'un_title' = '\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u0435 ToutWAF'
        'un_kept' = '\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438 \u0441\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u044b \u0432 {0}, \u0434\u0430\u043d\u043d\u044b\u0435 \u0432 {1} (--purge \u0434\u043b\u044f \u0443\u0434\u0430\u043b\u0435\u043d\u0438\u044f).'
        'un_purged' = '\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438, \u0434\u0430\u043d\u043d\u044b\u0435 \u0438 \u0436\u0443\u0440\u043d\u0430\u043b\u044b \u0443\u0434\u0430\u043b\u0435\u043d\u044b.'
        'p_console' = '\u0432\u0435\u0431-\u043a\u043e\u043d\u0441\u043e\u043b\u044c + API'
        'p_http' = 'HTTP (reverse proxy)'
        'p_https' = 'HTTPS (reverse proxy)'
        'p_dpapi' = 'API data plane: \u0422\u041e\u041b\u042c\u041a\u041e \u0435\u0441\u043b\u0438 data plane \u0440\u0430\u0431\u043e\u0442\u0430\u044e\u0442 \u043d\u0430 \u0414\u0420\u0423\u0413\u0418\u0425 \u0445\u043e\u0441\u0442\u0430\u0445 (\u043e\u0433\u0440\u0430\u043d\u0438\u0447\u044c\u0442\u0435 \u0438\u0445 IP)'
        'w_fw_manual' = '\u041f\u043e\u0440\u0442 {0}/tcp \u043d\u0435 \u043e\u0442\u043a\u0440\u044b\u0442 \u0430\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u0438: \u0441\u043c. \u043a\u043e\u043c\u0430\u043d\u0434\u044b \u0432 \u0438\u0442\u043e\u0433\u0430\u0445.'
        'need_cp' = '\u041f\u0440\u0438 \u0443\u043a\u0430\u0437\u0430\u043d\u0438\u0438 \u0442\u043e\u043a\u0435\u043d\u0430 \u0440\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0446\u0438\u0438 \u043d\u0443\u0436\u0435\u043d URL control plane.'
        'cp_title' = '\u0421\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u043e\u0441\u0442\u044c \u0441\u0438\u0441\u0442\u0435\u043c\u044b'
        'cp_detected' = '\u041e\u0431\u043d\u0430\u0440\u0443\u0436\u0435\u043d\u043e: {0}, \u0430\u0440\u0445. {1}, glibc {2}, systemd {3}, \u044f\u0434\u0440\u043e {4}'
        'cp_ok' = '\u0421\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u043e: {0} ({1})'
        'cp_tested' = '\u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u043e'
        'cp_expected' = '\u043e\u0436\u0438\u0434\u0430\u0435\u0442\u0441\u044f'
        'cp_w_like' = '{0} \u043d\u0435\u0442 \u0432 \u0442\u0430\u0431\u043b\u0438\u0446\u0435 \u0441\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u043e\u0441\u0442\u0438: \u043e\u0431\u0440\u0430\u0431\u0430\u0442\u044b\u0432\u0430\u0435\u0442\u0441\u044f \u043a\u0430\u043a \u0441\u0435\u043c\u0435\u0439\u0441\u0442\u0432\u043e {1} (\u043e\u0436\u0438\u0434\u0430\u0435\u0442\u0441\u044f). \u041f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u043c.'
        'cp_w_newer' = '{0} {1} \u043d\u043e\u0432\u0435\u0435 \u043f\u0435\u0440\u0435\u0447\u0438\u0441\u043b\u0435\u043d\u043d\u044b\u0445 \u0432\u0435\u0440\u0441\u0438\u0439: \u0435\u0449\u0451 \u043d\u0435 \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u043e (\u043e\u0436\u0438\u0434\u0430\u0435\u0442\u0441\u044f). \u041f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u043c.'
        'cp_w_unlisted' = '{0} {1} \u043d\u0435\u0442 \u0432 \u0442\u0430\u0431\u043b\u0438\u0446\u0435: \u0441\u0447\u0438\u0442\u0430\u0435\u0442\u0441\u044f \u043e\u0436\u0438\u0434\u0430\u0435\u043c\u043e \u0441\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u043e\u0439. \u041f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u043c.'
        'cp_w_nover' = '{0} \u043d\u0435 \u0441\u043e\u043e\u0431\u0449\u0430\u0435\u0442 \u0432\u0435\u0440\u0441\u0438\u044e (rolling \u0438\u043b\u0438 testing): \u0441\u0447\u0438\u0442\u0430\u0435\u0442\u0441\u044f \u043e\u0436\u0438\u0434\u0430\u0435\u043c\u043e \u0441\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u043e\u0439. \u041f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u043c.'
        'cp_w_glibc' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043e\u043f\u0440\u0435\u0434\u0435\u043b\u0438\u0442\u044c \u0432\u0435\u0440\u0441\u0438\u044e glibc; \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u043c.'
        'cp_w_skip' = '--skip-os-check: \u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0430 \u0441\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u043e\u0441\u0442\u0438 \u043f\u0440\u043e\u043f\u0443\u0449\u0435\u043d\u0430. \u042d\u0442\u0430 \u0441\u0438\u0441\u0442\u0435\u043c\u0430 \u041d\u0415 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u0442\u0441\u044f: \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u043c \u043d\u0430 \u0432\u0430\u0448 \u0440\u0438\u0441\u043a.'
        'cp_w_stage' = 'Staging (--destdir): \u0432\u0435\u0440\u0434\u0438\u043a\u0442 \u0441\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u043e\u0441\u0442\u0438 \u043d\u043e\u0441\u0438\u0442 \u0438\u043d\u0444\u043e\u0440\u043c\u0430\u0446\u0438\u043e\u043d\u043d\u044b\u0439 \u0445\u0430\u0440\u0430\u043a\u0442\u0435\u0440, \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u043e\u0442\u043a\u043b\u043e\u043d\u044f\u0435\u0442\u0441\u044f.'
        'cp_refused' = '\u042d\u0442\u0430 \u0441\u0438\u0441\u0442\u0435\u043c\u0430 \u043d\u0435\u0441\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u0430 \u0441 ToutWAF:'
        'cp_r_old' = '{0} {1} \u0441\u0442\u0430\u0440\u0448\u0435 \u043c\u0438\u043d\u0438\u043c\u0430\u043b\u044c\u043d\u043e\u0439 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u043c\u043e\u0439 \u0432\u0435\u0440\u0441\u0438\u0438 ({2}).'
        'cp_r_eol' = '{0} {1} \u0441\u043d\u044f\u0442\u0430 \u0441 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u043a\u0438, \u043b\u0438\u0431\u043e \u0435\u0451 glibc / systemd \u0441\u043b\u0438\u0448\u043a\u043e\u043c \u0441\u0442\u0430\u0440.'
        'cp_r_glibc' = '\u041d\u0430\u0439\u0434\u0435\u043d\u0430 glibc {0}: \u0442\u0440\u0435\u0431\u0443\u0435\u0442\u0441\u044f {1} \u0438\u043b\u0438 \u043d\u043e\u0432\u0435\u0435.'
        'cp_r_musl' = '\u041d\u0430\u0439\u0434\u0435\u043d\u0430 musl libc: \u0442\u0440\u0435\u0431\u0443\u0435\u0442\u0441\u044f glibc {0} \u0438\u043b\u0438 \u043d\u043e\u0432\u0435\u0435.'
        'cp_r_init' = '{0} {1} \u043d\u0435 \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0435\u0442 systemd, \u043a\u043e\u0442\u043e\u0440\u044b\u0439 \u043d\u0443\u0436\u0435\u043d ToutWAF.'
        'cp_r_immutable' = '{0} {1} \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0435\u0442 \u043d\u0435\u0438\u0437\u043c\u0435\u043d\u044f\u0435\u043c\u0443\u044e \u043a\u043e\u0440\u043d\u0435\u0432\u0443\u044e \u0424\u0421 (\u043d\u0435 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u0442\u0441\u044f).'
        'cp_r_layout' = '{0} {1} \u043d\u0435 \u0441\u043b\u0435\u0434\u0443\u0435\u0442 \u0441\u0442\u0430\u043d\u0434\u0430\u0440\u0442\u043d\u043e\u0439 \u0441\u0442\u0440\u0443\u043a\u0442\u0443\u0440\u0435 \u043a\u0430\u0442\u0430\u043b\u043e\u0433\u043e\u0432 Linux (\u043d\u0435 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u0442\u0441\u044f).'
        'cp_r_arch' = '\u0410\u0440\u0445\u0438\u0442\u0435\u043a\u0442\u0443\u0440\u0430 {0} \u043d\u0435 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u0442\u0441\u044f (\u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u0442\u0441\u044f: {1}).'
        'cp_r_distro_arch' = '{0} {1} \u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442 \u043d\u0430 \u0430\u0440\u0445\u0438\u0442\u0435\u043a\u0442\u0443\u0440\u0435 \u0431\u0435\u0437 \u0441\u0431\u043e\u0440\u043a\u0438 ToutWAF.'
        'cp_r_systemd' = 'systemd \u043d\u0435 \u0437\u0430\u043f\u0443\u0449\u0435\u043d \u043a\u0430\u043a init (\u043d\u0435\u0442 /run/systemd/system): \u043e\u043d \u043d\u0443\u0436\u0435\u043d \u0434\u043b\u044f \u0441\u043b\u0443\u0436\u0431.'
        'cp_r_systemd_old' = '\u041d\u0430\u0439\u0434\u0435\u043d systemd {0}: \u0442\u0440\u0435\u0431\u0443\u0435\u0442\u0441\u044f {1} \u0438\u043b\u0438 \u043d\u043e\u0432\u0435\u0435.'
        'cp_r_kernel' = '\u041d\u0430\u0439\u0434\u0435\u043d\u043e \u044f\u0434\u0440\u043e Linux {0}: \u0442\u0440\u0435\u0431\u0443\u0435\u0442\u0441\u044f {1} \u0438\u043b\u0438 \u043d\u043e\u0432\u0435\u0435.'
        'cp_r_unknown' = '\u0414\u0438\u0441\u0442\u0440\u0438\u0431\u0443\u0442\u0438\u0432 ''{0}'' \u043d\u0435 \u0440\u0430\u0441\u043f\u043e\u0437\u043d\u0430\u043d \u0438 \u043d\u0435 \u0443\u043a\u0430\u0437\u044b\u0432\u0430\u0435\u0442 \u0438\u0437\u0432\u0435\u0441\u0442\u043d\u043e\u0433\u043e \u0441\u0435\u043c\u0435\u0439\u0441\u0442\u0432\u0430 (ID_LIKE=''{1}'').'
        'cp_r_noosr' = '\u041d\u0435\u0442 /etc/os-release: \u0434\u0438\u0441\u0442\u0440\u0438\u0431\u0443\u0442\u0438\u0432 \u043e\u043f\u0440\u0435\u0434\u0435\u043b\u0438\u0442\u044c \u043d\u0435\u0432\u043e\u0437\u043c\u043e\u0436\u043d\u043e.'
        'cp_nochange' = '\u0412 \u0441\u0438\u0441\u0442\u0435\u043c\u0435 \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u043e.'
        'cp_list' = '\u0421\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u044b\u0435 \u0441\u0438\u0441\u0442\u0435\u043c\u044b (amd64 \u0438 arm64, glibc {0} \u0438\u043b\u0438 \u043d\u043e\u0432\u0435\u0435, systemd {1} \u0438\u043b\u0438 \u043d\u043e\u0432\u0435\u0435):'
        'cp_rolling' = 'rolling'
        'cp_any' = '\u043b\u044e\u0431\u0430\u044f \u0432\u0435\u0440\u0441\u0438\u044f'
        'cp_override' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c \u0432\u0441\u0451 \u0440\u0430\u0432\u043d\u043e, \u043d\u0430 \u0441\u0432\u043e\u0439 \u0440\u0438\u0441\u043a: --skip-os-check. \u041f\u043e\u0434\u0440\u043e\u0431\u043d\u043e\u0441\u0442\u0438: docs/install/platforms.md'
        'cp_not_root' = '\u0417\u0430\u043f\u0443\u0449\u0435\u043d\u043e \u043d\u0435 \u043e\u0442 root: \u0434\u043b\u044f \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438 \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0439\u0442\u0435 sudo (\u0441\u0430\u043c\u0430 \u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0430 root \u043d\u0435 \u0442\u0440\u0435\u0431\u0443\u0435\u0442).'
        'sum_compat' = '\u0421\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u043e\u0441\u0442\u044c'
        'cp_prereq_arch' = '\u0411\u0430\u0437\u044b \u043f\u0430\u043a\u0435\u0442\u043e\u0432 \u043d\u0435 \u0441\u0438\u043d\u0445\u0440\u043e\u043d\u0438\u0437\u0438\u0440\u043e\u0432\u0430\u043d\u044b. \u0421\u043d\u0430\u0447\u0430\u043b\u0430 \u0432\u044b\u043f\u043e\u043b\u043d\u0438\u0442\u0435 ''pacman -Syu'' (\u0447\u0430\u0441\u0442\u0438\u0447\u043d\u043e\u0435 \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435 \u0432 Arch \u043d\u0435 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u0442\u0441\u044f), \u0437\u0430\u0442\u0435\u043c \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430.'
        'cp_wdetected' = '\u041e\u0431\u043d\u0430\u0440\u0443\u0436\u0435\u043d\u043e: {0} (\u0441\u0431\u043e\u0440\u043a\u0430 {1}), \u0430\u0440\u0445. {2}'
        'cp_wlist' = '\u0421\u043e\u0432\u043c\u0435\u0441\u0442\u0438\u043c\u044b\u0435 \u0432\u0435\u0440\u0441\u0438\u0438 Windows (amd64 \u0438 arm64; arm64 \u043d\u0435 \u043f\u0440\u043e\u0432\u0435\u0440\u044f\u043b\u0430\u0441\u044c \u043d\u0430 \u0440\u0435\u0430\u043b\u044c\u043d\u043e\u043c \u043e\u0431\u043e\u0440\u0443\u0434\u043e\u0432\u0430\u043d\u0438\u0438):'
        'cp_r_arm32' = '32-\u0440\u0430\u0437\u0440\u044f\u0434\u043d\u044b\u0439 ARM (armv7) \u043d\u0435 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u0442\u0441\u044f ToutWAF. \u0423\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0435 64-\u0440\u0430\u0437\u0440\u044f\u0434\u043d\u0443\u044e \u041e\u0421 (Raspberry Pi OS 64-bit, Ubuntu \u0438\u043b\u0438 Debian arm64; Raspberry Pi 3, 4, 5 \u0438\u043b\u0438 Zero 2 W) \u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430.'
        'cp_r_arm_userland32' = '\u042f\u0434\u0440\u043e 64-\u0440\u0430\u0437\u0440\u044f\u0434\u043d\u043e\u0435, \u043d\u043e \u0441\u0438\u0441\u0442\u0435\u043c\u0430 (userland) 32-\u0440\u0430\u0437\u0440\u044f\u0434\u043d\u0430\u044f. ToutWAF \u043d\u0443\u0436\u043d\u0430 64-\u0440\u0430\u0437\u0440\u044f\u0434\u043d\u0430\u044f \u041e\u0421: \u043f\u0435\u0440\u0435\u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0435 \u0441 Raspberry Pi OS 64-bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) \u0438\u043b\u0438 Ubuntu / Debian arm64.'
        'cp_w_pi' = '\u041e\u0431\u043d\u0430\u0440\u0443\u0436\u0435\u043d Raspberry Pi: arm64 \u043f\u0440\u043e\u0432\u0435\u0440\u044f\u043b\u0430\u0441\u044c \u0442\u043e\u043b\u044c\u043a\u043e \u0432 \u044d\u043c\u0443\u043b\u044f\u0446\u0438\u0438, \u043d\u0435 \u043d\u0430 \u0440\u0435\u0430\u043b\u044c\u043d\u043e\u043c \u043e\u0431\u043e\u0440\u0443\u0434\u043e\u0432\u0430\u043d\u0438\u0438. \u0425\u0440\u0430\u043d\u0438\u0442\u0435 \u0434\u0430\u043d\u043d\u044b\u0435 \u0438 \u0436\u0443\u0440\u043d\u0430\u043b\u044b \u043d\u0430 SSD / USB-\u0434\u0438\u0441\u043a\u0435, \u0430 \u043d\u0435 \u043d\u0430 SD-\u043a\u0430\u0440\u0442\u0435, \u0438 \u0438\u0437\u0431\u0435\u0433\u0430\u0439\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438 \u00ab\u0432\u0441\u0451 \u0432 \u043e\u0434\u043d\u043e\u043c\u00bb \u043f\u0440\u0438 \u043c\u0435\u043d\u0435\u0435 \u0447\u0435\u043c 2 \u0413\u0411 \u041e\u0417\u0423 (\u0441\u043c. docs/install/raspberry-pi.md).'
        'pf_title' = '\u041f\u0440\u043e\u0432\u0435\u0440\u043a\u0430 \u0442\u043e\u0433\u043e, \u0447\u0442\u043e \u043d\u0443\u0436\u043d\u043e \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435'
        'pf_ok' = '\u041d\u0438\u0447\u0442\u043e \u043d\u0435 \u043c\u0435\u0448\u0430\u0435\u0442: \u043f\u043e\u0440\u0442\u044b, \u043d\u0443\u0436\u043d\u044b\u0435 ToutWAF, \u0441\u0432\u043e\u0431\u043e\u0434\u043d\u044b.'
        'pf_refused' = 'ToutWAF \u043d\u0435\u043b\u044c\u0437\u044f \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c \u043d\u0430 \u044d\u0442\u0443 \u043c\u0430\u0448\u0438\u043d\u0443 \u0432 \u0435\u0451 \u043d\u044b\u043d\u0435\u0448\u043d\u0435\u043c \u0441\u043e\u0441\u0442\u043e\u044f\u043d\u0438\u0438. \u041d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u043e.'
        'pf_ok_warn' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0435 \u043d\u0438\u0447\u0442\u043e \u043d\u0435 \u043c\u0435\u0448\u0430\u0435\u0442, \u043d\u043e \u043f\u0440\u043e\u0447\u0438\u0442\u0430\u0439\u0442\u0435 \u043f\u0443\u043d\u043a\u0442\u044b \u0432\u044b\u0448\u0435.'
        'pf_l_refuse' = '\u043e\u0442\u043a\u0430\u0437'
        'pf_l_warn' = '\u0432\u043d\u0438\u043c\u0430\u043d\u0438\u0435'
        'pf_l_info' = '\u0437\u0430\u043c\u0435\u0442\u043a\u0430'
        'pf_port_busy' = '\u041f\u043e\u0440\u0442 {0} \u0443\u0436\u0435 \u0437\u0430\u043d\u044f\u0442: {1}.'
        'pf_prog_other' = '\u0434\u0440\u0443\u0433\u0430\u044f \u043f\u0440\u043e\u0433\u0440\u0430\u043c\u043c\u0430'
        'pf_prog_unknown' = '\u0434\u0440\u0443\u0433\u0430\u044f \u043f\u0440\u043e\u0433\u0440\u0430\u043c\u043c\u0430 (\u0435\u0451 \u0438\u043c\u044f \u043d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043f\u0440\u043e\u0447\u0438\u0442\u0430\u0442\u044c)'
        'pf_act_web' = 'ToutWAF \u043d\u0443\u0436\u043d\u044b \u043f\u043e\u0440\u0442\u044b {0} \u0438 {1}, \u0447\u0442\u043e\u0431\u044b \u0437\u0430\u0449\u0438\u0449\u0430\u0442\u044c \u0432\u0430\u0448\u0438 \u0441\u0430\u0439\u0442\u044b. \u041e\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0435 \u044d\u0442\u0443 \u043f\u0440\u043e\u0433\u0440\u0430\u043c\u043c\u0443 \u0438\u043b\u0438 \u043f\u0435\u0440\u0435\u043d\u0435\u0441\u0438\u0442\u0435 \u0435\u0451 \u043d\u0430 \u0434\u0440\u0443\u0433\u0438\u0435 \u043f\u043e\u0440\u0442\u044b (ToutPanel, \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043d\u044b\u0439 \u0440\u044f\u0434\u043e\u043c \u0441 ToutWAF, \u0440\u0430\u0437\u043c\u0435\u0449\u0430\u0435\u0442 \u0441\u0432\u043e\u0439 \u0432\u0435\u0431-\u0441\u0435\u0440\u0432\u0435\u0440 \u043d\u0430 \u043f\u043e\u0440\u0442\u0430\u0445 8080 \u0438 8443) \u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430.'
        'pf_act_console' = '\u042d\u0442\u043e\u0442 \u043f\u043e\u0440\u0442 \u043d\u0443\u0436\u0435\u043d \u043a\u043e\u043d\u0441\u043e\u043b\u0438 ToutWAF. \u041e\u0441\u0432\u043e\u0431\u043e\u0434\u0438\u0442\u0435 \u0435\u0433\u043e \u0438\u043b\u0438 \u0432\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u0434\u0440\u0443\u0433\u043e\u0439 \u043f\u043e\u0440\u0442 \u043a\u043e\u043d\u0441\u043e\u043b\u0438 (\u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043f\u0440\u0430\u0448\u0438\u0432\u0430\u0435\u0442 \u043e\u0431 \u044d\u0442\u043e\u043c \u0432 \u0441\u0432\u043e\u0451\u043c \u043c\u0435\u043d\u044e) \u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430.'
        'pf_act_agent' = 'ToutWAF \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0435\u0442 \u044d\u0442\u043e\u0442 \u043f\u043e\u0440\u0442 \u0434\u043b\u044f \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0430\u044e\u0449\u0438\u0445\u0441\u044f \u043a \u043d\u0435\u043c\u0443 \u0443\u0437\u043b\u043e\u0432 \u043e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0438 \u0434\u0430\u043d\u043d\u044b\u0445 \u0438 \u0430\u0433\u0435\u043d\u0442\u043e\u0432. \u041e\u0441\u0432\u043e\u0431\u043e\u0434\u0438\u0442\u0435 \u0435\u0433\u043e \u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430.'
        'pf_act_admin' = '\u0423\u0437\u0435\u043b \u043e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0438 \u0434\u0430\u043d\u043d\u044b\u0445 \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0435\u0442 \u044d\u0442\u043e\u0442 \u043f\u043e\u0440\u0442 \u0442\u043e\u043b\u044c\u043a\u043e \u043d\u0430 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435, \u0434\u043b\u044f \u0441\u043e\u0431\u0441\u0442\u0432\u0435\u043d\u043d\u043e\u0439 \u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0438 \u0441\u043e\u0441\u0442\u043e\u044f\u043d\u0438\u044f. \u041e\u0441\u0432\u043e\u0431\u043e\u0434\u0438\u0442\u0435 \u0435\u0433\u043e \u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430.'
        'pf_nostart' = '(\u0441\u0435\u0439\u0447\u0430\u0441 \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0437\u0430\u043f\u0443\u0441\u043a\u0430\u0435\u0442\u0441\u044f, \u043f\u043e\u044d\u0442\u043e\u043c\u0443 \u044d\u0442\u043e \u043b\u0438\u0448\u044c \u0441\u043e\u043e\u0431\u0449\u0435\u043d\u0438\u0435)'
        'pf_boot' = '{0} \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d \u0438 \u0437\u0430\u043f\u0443\u0441\u043a\u0430\u0435\u0442\u0441\u044f \u0432\u043c\u0435\u0441\u0442\u0435 \u0441 \u043c\u0430\u0448\u0438\u043d\u043e\u0439, \u0445\u043e\u0442\u044f \u0441\u0435\u0439\u0447\u0430\u0441 \u043e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d. \u041f\u043e\u0441\u043b\u0435 \u0441\u043b\u0435\u0434\u0443\u044e\u0449\u0435\u0439 \u043f\u0435\u0440\u0435\u0437\u0430\u0433\u0440\u0443\u0437\u043a\u0438 \u043e\u043d \u0437\u0430\u0439\u043c\u0451\u0442 \u043f\u043e\u0440\u0442\u044b {1} \u0438 {2} \u0440\u0430\u043d\u044c\u0448\u0435 ToutWAF.'
        'pf_act_boot' = '\u041e\u0442\u043a\u043b\u044e\u0447\u0438\u0442\u0435 \u0435\u0433\u043e \u0430\u0432\u0442\u043e\u0437\u0430\u043f\u0443\u0441\u043a \u0438\u043b\u0438 \u043f\u0435\u0440\u0435\u043d\u0435\u0441\u0438\u0442\u0435 \u043d\u0430 \u0434\u0440\u0443\u0433\u0438\u0435 \u043f\u043e\u0440\u0442\u044b \u0434\u043e \u043f\u0435\u0440\u0435\u0437\u0430\u0433\u0440\u0443\u0437\u043a\u0438 \u043c\u0430\u0448\u0438\u043d\u044b.'
        'pf_fw_cause' = '\u0410\u043a\u0442\u0438\u0432\u0435\u043d \u043c\u0435\u0436\u0441\u0435\u0442\u0435\u0432\u043e\u0439 \u044d\u043a\u0440\u0430\u043d ({0}), \u043e\u043d \u043d\u0435 \u043f\u0440\u043e\u043f\u0443\u0441\u043a\u0430\u0435\u0442 \u043f\u043e\u0440\u0442\u044b {1} \u0438 {2}, \u0430 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a\u0443 \u0432\u0435\u043b\u0435\u043d\u043e \u0435\u0433\u043e \u043d\u0435 \u043c\u0435\u043d\u044f\u0442\u044c.'
        'pf_fw_action' = '\u041e\u0442\u043a\u0440\u043e\u0439\u0442\u0435 \u044d\u0442\u0438 \u043f\u043e\u0440\u0442\u044b \u0432 \u043c\u0435\u0436\u0441\u0435\u0442\u0435\u0432\u043e\u043c \u044d\u043a\u0440\u0430\u043d\u0435 \u0438\u043b\u0438 \u043f\u043e\u0437\u0432\u043e\u043b\u044c\u0442\u0435 \u044d\u0442\u043e \u0441\u0434\u0435\u043b\u0430\u0442\u044c \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a\u0443 (\u0431\u0435\u0437 \u043f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u0430 --no-firewall). \u0418\u043d\u0430\u0447\u0435 \u0432\u0430\u0448\u0438 \u0441\u0430\u0439\u0442\u044b \u0431\u0443\u0434\u0443\u0442 \u043d\u0435\u0434\u043e\u0441\u0442\u0443\u043f\u043d\u044b \u0441\u043d\u0430\u0440\u0443\u0436\u0438.'
        'pf_fwx_cause' = '\u041c\u0435\u0436\u0441\u0435\u0442\u0435\u0432\u043e\u0439 \u044d\u043a\u0440\u0430\u043d \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u044b ({0}) \u043f\u043e \u0443\u043c\u043e\u043b\u0447\u0430\u043d\u0438\u044e \u043e\u0442\u043a\u043b\u043e\u043d\u044f\u0435\u0442 \u0432\u0445\u043e\u0434\u044f\u0449\u0438\u0435 \u0441\u043e\u0435\u0434\u0438\u043d\u0435\u043d\u0438\u044f \u0438 \u043d\u0435 \u0438\u043c\u0435\u0435\u0442 \u043f\u0440\u0430\u0432\u0438\u043b \u0434\u043b\u044f \u043f\u043e\u0440\u0442\u043e\u0432 {1} \u0438 {2}.'
        'pf_fwx_action' = 'ToutWAF \u043d\u0438\u043a\u043e\u0433\u0434\u0430 \u0441\u0430\u043c \u043d\u0435 \u043c\u0435\u043d\u044f\u0435\u0442 \u043f\u0440\u0430\u0432\u0438\u043b\u0430 \u0442\u0430\u043a\u043e\u0433\u043e \u043c\u0435\u0436\u0441\u0435\u0442\u0435\u0432\u043e\u0433\u043e \u044d\u043a\u0440\u0430\u043d\u0430: \u043e\u0442\u043a\u0440\u043e\u0439\u0442\u0435 \u044d\u0442\u0438 \u043f\u043e\u0440\u0442\u044b \u0432 \u0435\u0433\u043e \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0430\u0445, \u0437\u0430\u0442\u0435\u043c \u043f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435 \u0441\u0432\u043e\u0438 \u0441\u0430\u0439\u0442\u044b.'
        'pf_cp_cause' = '\u0423\u043f\u0440\u0430\u0432\u043b\u044f\u044e\u0449\u0438\u0439 \u0443\u0437\u0435\u043b {0} \u043d\u0435\u0434\u043e\u0441\u0442\u0443\u043f\u0435\u043d \u0441 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u044b.'
        'pf_cp_action' = '\u041f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435 \u0430\u0434\u0440\u0435\u0441, \u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442 \u043b\u0438 \u0443\u043f\u0440\u0430\u0432\u043b\u044f\u044e\u0449\u0438\u0439 \u0443\u0437\u0435\u043b \u0438 \u043f\u0440\u043e\u043f\u0443\u0441\u043a\u0430\u0435\u0442 \u043b\u0438 \u0435\u0433\u043e \u043c\u0435\u0436\u0441\u0435\u0442\u0435\u0432\u043e\u0439 \u044d\u043a\u0440\u0430\u043d \u044d\u0442\u0443 \u043c\u0430\u0448\u0438\u043d\u0443 (\u043f\u043e \u0443\u043c\u043e\u043b\u0447\u0430\u043d\u0438\u044e \u043f\u043e\u0440\u0442 9444), \u0438 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441\u043d\u043e\u0432\u0430.'
        'pf_router_cause' = '\u0423 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u044b \u0447\u0430\u0441\u0442\u043d\u044b\u0439 \u0430\u0434\u0440\u0435\u0441 ({0}): \u0441\u043a\u043e\u0440\u0435\u0435 \u0432\u0441\u0435\u0433\u043e, \u043e\u043d\u0430 \u043d\u0430\u0445\u043e\u0434\u0438\u0442\u0441\u044f \u0437\u0430 \u043c\u0430\u0440\u0448\u0440\u0443\u0442\u0438\u0437\u0430\u0442\u043e\u0440\u043e\u043c.'
        'pf_router_action' = '\u041f\u043e\u0441\u043b\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438 ToutWAF \u043f\u043e\u043a\u0430\u0436\u0435\u0442, \u043a\u0430\u043a\u0438\u0435 \u043f\u043e\u0440\u0442\u044b \u043d\u0443\u0436\u043d\u043e \u043f\u0440\u043e\u0431\u0440\u043e\u0441\u0438\u0442\u044c \u043d\u0430 \u044d\u0442\u0443 \u043c\u0430\u0448\u0438\u043d\u0443, \u0438 \u0434\u0430\u0441\u0442 \u0444\u0430\u0439\u043b\u044b \u0434\u043b\u044f \u0440\u0430\u0441\u043f\u0440\u043e\u0441\u0442\u0440\u0430\u043d\u0451\u043d\u043d\u044b\u0445 \u043c\u0430\u0440\u0448\u0440\u0443\u0442\u0438\u0437\u0430\u0442\u043e\u0440\u043e\u0432. \u0421\u0435\u0439\u0447\u0430\u0441 \u043d\u0438\u0447\u0435\u0433\u043e \u0433\u043e\u0442\u043e\u0432\u0438\u0442\u044c \u043d\u0435 \u043d\u0443\u0436\u043d\u043e.'
        'pf_skipped' = '\u041f\u0440\u043e\u0432\u0435\u0440\u043a\u0430 \u043e\u043a\u0440\u0443\u0436\u0435\u043d\u0438\u044f \u043f\u0440\u043e\u043f\u0443\u0449\u0435\u043d\u0430 \u043f\u043e \u0432\u0430\u0448\u0435\u0439 \u043f\u0440\u043e\u0441\u044c\u0431\u0435: \u0442\u043e, \u0447\u0442\u043e \u043c\u0435\u0448\u0430\u0435\u0442, \u043f\u0440\u0438\u0432\u0435\u0434\u0451\u0442 \u043a \u0441\u0431\u043e\u044e \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438 \u0438\u043b\u0438 \u0437\u0430\u043f\u0443\u0441\u043a\u0430 \u043f\u043e\u0437\u0436\u0435.'
        's_sysupdate' = '\u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435 \u0441\u0438\u0441\u0442\u0435\u043c\u043d\u044b\u0445 \u043f\u0430\u043a\u0435\u0442\u043e\u0432 (\u044d\u0442\u043e \u043c\u043e\u0436\u0435\u0442 \u0437\u0430\u043d\u044f\u0442\u044c \u043d\u0435\u0441\u043a\u043e\u043b\u044c\u043a\u043e \u043c\u0438\u043d\u0443\u0442)'
        'su_skipped' = '\u0421\u0438\u0441\u0442\u0435\u043c\u043d\u044b\u0435 \u043f\u0430\u043a\u0435\u0442\u044b \u043f\u0440\u0435\u0434\u0432\u0430\u0440\u0438\u0442\u0435\u043b\u044c\u043d\u043e \u043d\u0435 \u043e\u0431\u043d\u043e\u0432\u043b\u044f\u044e\u0442\u0441\u044f (TOUTWAF_SKIP_SYSUPDATE).'
        'su_recent' = '\u0421\u0438\u0441\u0442\u0435\u043c\u043d\u044b\u0435 \u043f\u0430\u043a\u0435\u0442\u044b \u043e\u0431\u043d\u043e\u0432\u043b\u044f\u043b\u0438\u0441\u044c \u043c\u0435\u043d\u0435\u0435 6 \u0447\u0430\u0441\u043e\u0432 \u043d\u0430\u0437\u0430\u0434: \u043f\u043e\u0432\u0442\u043e\u0440\u043d\u043e \u043d\u0435 \u043e\u0431\u043d\u043e\u0432\u043b\u044f\u044e\u0442\u0441\u044f.'
        'su_dry' = '\u0441\u043d\u0430\u0447\u0430\u043b\u0430 \u0431\u044b\u043b\u0438 \u0431\u044b \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u044b \u0441\u0438\u0441\u0442\u0435\u043c\u043d\u044b\u0435 \u043f\u0430\u043a\u0435\u0442\u044b (\u043f\u0440\u043e\u043f\u0443\u0441\u0442\u0438\u0442\u044c: TOUTWAF_SKIP_SYSUPDATE=1)'
        'su_nopm' = '\u041d\u0435\u0442 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u043c\u043e\u0433\u043e \u043c\u0435\u043d\u0435\u0434\u0436\u0435\u0440\u0430 \u043f\u0430\u043a\u0435\u0442\u043e\u0432 \u0434\u043b\u044f \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f \u0441\u0438\u0441\u0442\u0435\u043c\u044b: \u0448\u0430\u0433 \u043f\u0440\u043e\u043f\u0443\u0449\u0435\u043d, \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u0442\u0441\u044f.'
        'su_failed' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043e\u0431\u043d\u043e\u0432\u0438\u0442\u044c \u0441\u0438\u0441\u0442\u0435\u043c\u043d\u044b\u0435 \u043f\u0430\u043a\u0435\u0442\u044b (\u043a\u043e\u0434 {0}); \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0435\u0442\u0441\u044f \u0431\u0435\u0437 \u044d\u0442\u043e\u0433\u043e. \u041f\u043e\u0434\u0440\u043e\u0431\u043d\u043e\u0441\u0442\u0438: {1}. \u0427\u0442\u043e \u0434\u0435\u043b\u0430\u0442\u044c: \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435 \u0432\u0440\u0443\u0447\u043d\u0443\u044e \u0438 \u043f\u0440\u043e\u0447\u0438\u0442\u0430\u0439\u0442\u0435 \u043e\u0448\u0438\u0431\u043a\u0443 (\u043f\u043e\u0432\u0440\u0435\u0436\u0434\u0451\u043d \u0440\u0435\u043f\u043e\u0437\u0438\u0442\u043e\u0440\u0438\u0439? \u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442 \u0434\u0440\u0443\u0433\u043e\u0439 \u043c\u0435\u043d\u0435\u0434\u0436\u0435\u0440 \u043f\u0430\u043a\u0435\u0442\u043e\u0432?) \u043b\u0438\u0431\u043e \u043f\u043e\u0432\u0442\u043e\u0440\u0438\u0442\u0435 \u044d\u0442\u0443 \u043a\u043e\u043c\u0430\u043d\u0434\u0443 \u0441 TOUTWAF_SKIP_SYSUPDATE=1.'
        'su_reboot' = '\u0414\u043b\u044f \u0437\u0430\u0432\u0435\u0440\u0448\u0435\u043d\u0438\u044f \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f \u0441\u0438\u0441\u0442\u0435\u043c\u044b \u043d\u0443\u0436\u043d\u043e \u043f\u0435\u0440\u0435\u0437\u0430\u0433\u0440\u0443\u0437\u0438\u0442\u044c \u044d\u0442\u043e\u0442 \u0441\u0435\u0440\u0432\u0435\u0440 (\u043d\u043e\u0432\u043e\u0435 \u044f\u0434\u0440\u043e \u0438\u043b\u0438 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438). ToutWAF \u043d\u0438\u043a\u043e\u0433\u0434\u0430 \u043d\u0435 \u043f\u0435\u0440\u0435\u0437\u0430\u0433\u0440\u0443\u0436\u0430\u0435\u0442 \u0435\u0433\u043e \u0437\u0430 \u0432\u0430\u0441: \u0441\u0434\u0435\u043b\u0430\u0439\u0442\u0435 \u044d\u0442\u043e, \u043a\u043e\u0433\u0434\u0430 \u0441\u043c\u043e\u0436\u0435\u0442\u0435.'
        'q_sysupdate' = '\u0421\u043d\u0430\u0447\u0430\u043b\u0430 \u043e\u0431\u043d\u043e\u0432\u0438\u0442\u044c \u0441\u0438\u0441\u0442\u0435\u043c\u043d\u044b\u0435 \u043f\u0430\u043a\u0435\u0442\u044b (\u0440\u0435\u043a\u043e\u043c\u0435\u043d\u0434\u0443\u0435\u0442\u0441\u044f)?'
        'pr_disk_full' = '\u0421\u0432\u043e\u0431\u043e\u0434\u043d\u043e \u0442\u043e\u043b\u044c\u043a\u043e {0} \u041c\u0411 \u043d\u0430 {1} (\u043d\u0443\u0436\u043d\u043e \u043d\u0435 \u043c\u0435\u043d\u0435\u0435 {2} \u041c\u0411): \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u043d\u0435 \u0441\u043c\u043e\u0436\u0435\u0442 \u0437\u0430\u0432\u0435\u0440\u0448\u0438\u0442\u044c\u0441\u044f.'
        'pr_disk_full_a' = '\u041e\u0441\u0432\u043e\u0431\u043e\u0434\u0438\u0442\u0435 \u043c\u0435\u0441\u0442\u043e (\u043a\u044d\u0448 \u043f\u0430\u043a\u0435\u0442\u043e\u0432: apt-get clean \u0438\u043b\u0438 dnf clean all; \u0441\u0442\u0430\u0440\u044b\u0435 \u0436\u0443\u0440\u043d\u0430\u043b\u044b: journalctl --vacuum-size=100M) \u0438 \u043f\u043e\u0432\u0442\u043e\u0440\u0438\u0442\u0435 \u044d\u0442\u0443 \u043a\u043e\u043c\u0430\u043d\u0434\u0443. \u0427\u0442\u043e\u0431\u044b \u0432\u0441\u0451 \u0440\u0430\u0432\u043d\u043e \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0438\u0442\u044c: TOUTWAF_SKIP_PREREQ=1.'
        'pr_disk_full_w_a' = '\u041e\u0441\u0432\u043e\u0431\u043e\u0434\u0438\u0442\u0435 \u043c\u0435\u0441\u0442\u043e (\u041e\u0447\u0438\u0441\u0442\u043a\u0430 \u0434\u0438\u0441\u043a\u0430, \u043e\u0447\u0438\u0441\u0442\u043a\u0430 \u043a\u043e\u0440\u0437\u0438\u043d\u044b) \u0438 \u043f\u043e\u0432\u0442\u043e\u0440\u0438\u0442\u0435 \u044d\u0442\u0443 \u043a\u043e\u043c\u0430\u043d\u0434\u0443. \u0427\u0442\u043e\u0431\u044b \u0432\u0441\u0451 \u0440\u0430\u0432\u043d\u043e \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0438\u0442\u044c: $env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = '\u0421\u0432\u043e\u0431\u043e\u0434\u043d\u043e \u0442\u043e\u043b\u044c\u043a\u043e {0} \u041c\u0411 \u043d\u0430 {1} (\u043a\u043e\u043c\u0444\u043e\u0440\u0442\u043d\u043e \u2014 \u043e\u043a\u043e\u043b\u043e {2} \u041c\u0411).'
        'pr_disk_low_a' = '\u041e\u0441\u0432\u043e\u0431\u043e\u0434\u0438\u0442\u0435 \u043c\u0435\u0441\u0442\u043e \u0438\u043b\u0438 \u0434\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0434\u0438\u0441\u043a; \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u043c\u043e\u0436\u0435\u0442 \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0430\u0442\u044c\u0441\u044f.'
        'pr_dns' = '\u042d\u0442\u0430 \u043c\u0430\u0448\u0438\u043d\u0430 \u043d\u0435 \u043c\u043e\u0436\u0435\u0442 \u0440\u0430\u0437\u0440\u0435\u0448\u0438\u0442\u044c \u0438\u043c\u044f {0} (DNS).'
        'pr_dns_a' = '\u041f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435 DNS-\u0441\u0435\u0440\u0432\u0435\u0440\u044b (cat /etc/resolv.conf, resolvectl status), \u0434\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0440\u0430\u0431\u043e\u0447\u0438\u0439, \u043d\u0430\u043f\u0440\u0438\u043c\u0435\u0440 nameserver 9.9.9.9, \u0438 \u043f\u043e\u0432\u0442\u043e\u0440\u0438\u0442\u0435 \u044d\u0442\u0443 \u043a\u043e\u043c\u0430\u043d\u0434\u0443.'
        'pr_dns_w_a' = '\u041f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435 DNS-\u0441\u0435\u0440\u0432\u0435\u0440\u044b \u043a\u043e\u043c\u0430\u043d\u0434\u043e\u0439 ''ipconfig /all'', \u0443\u043a\u0430\u0436\u0438\u0442\u0435 \u0440\u0430\u0431\u043e\u0447\u0438\u0439 (\u043d\u0430\u043f\u0440\u0438\u043c\u0435\u0440, 9.9.9.9) \u0432 \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0430\u0445 \u0441\u0435\u0442\u0435\u0432\u043e\u0433\u043e \u0430\u0434\u0430\u043f\u0442\u0435\u0440\u0430 \u0438 \u043f\u043e\u0432\u0442\u043e\u0440\u0438\u0442\u0435 \u044d\u0442\u0443 \u043a\u043e\u043c\u0430\u043d\u0434\u0443.'
        'pr_clock' = '\u0427\u0430\u0441\u044b \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u044b \u0440\u0430\u0441\u0445\u043e\u0434\u044f\u0442\u0441\u044f \u0441 \u0438\u043d\u0442\u0435\u0440\u043d\u0435\u0442-\u0432\u0440\u0435\u043c\u0435\u043d\u0435\u043c \u043d\u0430 {0} \u0441: \u0441\u0435\u0440\u0442\u0438\u0444\u0438\u043a\u0430\u0442\u044b TLS \u0438 \u043f\u043e\u0434\u043f\u0438\u0441\u0438 \u043d\u0435 \u043f\u0440\u043e\u0445\u043e\u0434\u044f\u0442 \u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0443 \u043f\u0440\u0438 \u043d\u0435\u0432\u0435\u0440\u043d\u044b\u0445 \u0447\u0430\u0441\u0430\u0445.'
        'pr_clock_a' = '\u0421\u0438\u043d\u0445\u0440\u043e\u043d\u0438\u0437\u0438\u0440\u0443\u0439\u0442\u0435 \u0447\u0430\u0441\u044b: timedatectl set-ntp true (\u0438\u043b\u0438 chronyc makestep), \u043f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435 \u0447\u0435\u0440\u0435\u0437 timedatectl \u0438 \u043f\u043e\u0432\u0442\u043e\u0440\u0438\u0442\u0435 \u044d\u0442\u0443 \u043a\u043e\u043c\u0430\u043d\u0434\u0443.'
        'pr_clock_w_a' = '\u0421\u0438\u043d\u0445\u0440\u043e\u043d\u0438\u0437\u0438\u0440\u0443\u0439\u0442\u0435 \u0447\u0430\u0441\u044b: w32tm /resync (\u0438\u043b\u0438 \u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u044b > \u0412\u0440\u0435\u043c\u044f \u0438 \u044f\u0437\u044b\u043a > \u0421\u0438\u043d\u0445\u0440\u043e\u043d\u0438\u0437\u0438\u0440\u043e\u0432\u0430\u0442\u044c) \u0438 \u043f\u043e\u0432\u0442\u043e\u0440\u0438\u0442\u0435 \u044d\u0442\u0443 \u043a\u043e\u043c\u0430\u043d\u0434\u0443.'
        'pr_ok' = '\u041c\u0435\u0441\u0442\u043e \u043d\u0430 \u0434\u0438\u0441\u043a\u0435, DNS \u0438 \u0447\u0430\u0441\u044b \u0432 \u043f\u043e\u0440\u044f\u0434\u043a\u0435.'
        'cloud_https' = '--cloud-url \u0434\u043e\u043b\u0436\u0435\u043d \u0431\u044b\u0442\u044c \u0430\u0434\u0440\u0435\u0441\u043e\u043c https:// (\u0443\u0437\u0435\u043b \u043d\u0438\u043a\u043e\u0433\u0434\u0430 \u043d\u0435 \u043e\u0431\u0449\u0430\u0435\u0442\u0441\u044f \u0441 \u043e\u0431\u043b\u0430\u043a\u043e\u043c \u0432 \u043e\u0442\u043a\u0440\u044b\u0442\u043e\u043c \u0432\u0438\u0434\u0435).'
        'cloud_dp_only' = '--cloud-url \u0443\u0441\u0442\u0430\u043d\u0430\u0432\u043b\u0438\u0432\u0430\u0435\u0442 \u0443\u0437\u0435\u043b \u0437\u0430\u0449\u0438\u0442\u044b: \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0439\u0442\u0435 \u0435\u0433\u043e \u0441 --component dp (\u043f\u043e \u0443\u043c\u043e\u043b\u0447\u0430\u043d\u0438\u044e \u0432 \u043e\u0431\u043b\u0430\u0447\u043d\u043e\u043c \u0440\u0435\u0436\u0438\u043c\u0435).'
        'cloud_need_token' = '\u0414\u043b\u044f \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u044f \u044d\u0442\u043e\u0433\u043e \u0443\u0437\u043b\u0430 \u043a \u0432\u0430\u0448\u0435\u0439 \u0443\u0447\u0451\u0442\u043d\u043e\u0439 \u0437\u0430\u043f\u0438\u0441\u0438 \u043d\u0443\u0436\u0435\u043d \u0442\u043e\u043a\u0435\u043d \u0440\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0446\u0438\u0438 (--enroll-token; \u043a\u043e\u043d\u0441\u043e\u043b\u044c: \u0423\u0437\u043b\u044b > \u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c \u043f\u0435\u0440\u0432\u044b\u0439 \u0443\u0437\u0435\u043b).'
        'cloud_ca_local' = '--cloud-ca \u0434\u043e\u043b\u0436\u0435\u043d \u0431\u044b\u0442\u044c \u043b\u043e\u043a\u0430\u043b\u044c\u043d\u044b\u043c \u0444\u0430\u0439\u043b\u043e\u043c.'
        'cloud_nolink' = '\u0412 \u044d\u0442\u043e\u0439 \u0432\u0435\u0440\u0441\u0438\u0438 \u043d\u0435\u0442 \u043a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442\u0430 \u0441\u0432\u044f\u0437\u0438 ToutWAF Cloud (toutwaf-cloudlink): \u043e\u0431\u043d\u043e\u0432\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0438\u043b\u0438 \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0439\u0442\u0435 \u0431\u043e\u043b\u0435\u0435 \u043d\u043e\u0432\u0443\u044e \u0432\u0435\u0440\u0441\u0438\u044e.'
        'cloud_enrol_failed' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0437\u0430\u0440\u0435\u0433\u0438\u0441\u0442\u0440\u0438\u0440\u043e\u0432\u0430\u0442\u044c \u0443\u0437\u0435\u043b \u0432 \u0432\u0430\u0448\u0435\u0439 \u0443\u0447\u0451\u0442\u043d\u043e\u0439 \u0437\u0430\u043f\u0438\u0441\u0438 (\u0441\u043c. \u0441\u0442\u0440\u043e\u043a\u0438 \u0432\u044b\u0448\u0435). \u0422\u043e\u043a\u0435\u043d \u043c\u043e\u0433 \u0431\u044b\u0442\u044c \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u043d \u0438\u043b\u0438 \u0438\u0441\u0442\u0435\u0447\u044c: \u0441\u043e\u0437\u0434\u0430\u0439\u0442\u0435 \u043d\u043e\u0432\u044b\u0439 \u0432 \u043a\u043e\u043d\u0441\u043e\u043b\u0438.'
        'pf_cloud_action' = '\u0420\u0430\u0437\u0440\u0435\u0448\u0438\u0442\u0435 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435 \u043e\u0431\u0440\u0430\u0449\u0430\u0442\u044c\u0441\u044f \u043a \u0430\u0434\u0440\u0435\u0441\u0443 \u0432\u0430\u0448\u0435\u0433\u043e ToutWAF Cloud \u043f\u043e \u043f\u043e\u0440\u0442\u0443 443 (\u0442\u043e\u043b\u044c\u043a\u043e \u0438\u0441\u0445\u043e\u0434\u044f\u0449\u0438\u0435) \u0438\u043b\u0438 \u0437\u0430\u0434\u0430\u0439\u0442\u0435 HTTPS_PROXY, \u0435\u0441\u043b\u0438 \u043d\u0443\u0436\u0435\u043d \u043f\u0440\u043e\u043a\u0441\u0438. \u0414\u043b\u044f \u0432\u0445\u043e\u0434\u044f\u0449\u0435\u0433\u043e \u0442\u0440\u0430\u0444\u0438\u043a\u0430 \u043d\u0438\u0447\u0435\u0433\u043e \u043e\u0442\u043a\u0440\u044b\u0432\u0430\u0442\u044c \u043d\u0435 \u043d\u0443\u0436\u043d\u043e.'
        's_db' = '\u041f\u043e\u0434\u0433\u043e\u0442\u043e\u0432\u043a\u0430 \u0431\u0430\u0437\u044b \u0434\u0430\u043d\u043d\u044b\u0445'
        'db_choose' = '\u041a\u0430\u043a\u0443\u044e \u0431\u0430\u0437\u0443 \u0434\u0430\u043d\u043d\u044b\u0445 \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u044c ToutWAF?'
        'db_opt_pg' = 'PostgreSQL (\u0440\u0435\u043a\u043e\u043c\u0435\u043d\u0434\u0443\u0435\u0442\u0441\u044f)'
        'db_opt_pg_local' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c PostgreSQL \u043d\u0430 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435 (\u0441\u043e\u0437\u0434\u0430\u0451\u0442\u0441\u044f \u0438 \u043d\u0430\u0441\u0442\u0440\u0430\u0438\u0432\u0430\u0435\u0442\u0441\u044f \u0430\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u0438)'
        'db_opt_pg_remote' = '\u0418\u0441\u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u044c \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0449\u0438\u0439 \u0441\u0435\u0440\u0432\u0435\u0440 PostgreSQL (\u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0430 \u0438 \u043f\u043e\u0434\u0433\u043e\u0442\u043e\u0432\u043a\u0430, \u0435\u0441\u043b\u0438 \u0440\u0430\u0437\u0440\u0435\u0448\u0438\u0442\u0435)'
        'db_opt_sqlite' = 'SQLite (\u043d\u0435\u0431\u043e\u043b\u044c\u0448\u0430\u044f \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430, \u043e\u0434\u0438\u043d \u0441\u0435\u0440\u0432\u0435\u0440)'
        'db_sqlite_note' = 'SQLite \u2014 \u044d\u0442\u043e \u043e\u0434\u0438\u043d \u0444\u0430\u0439\u043b \u043d\u0430 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435: \u043f\u043e\u0434\u0445\u043e\u0434\u0438\u0442 \u0434\u043b\u044f \u043d\u0435\u0431\u043e\u043b\u044c\u0448\u043e\u0439 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438 \u043d\u0430 \u043e\u0434\u043d\u043e\u043c \u0441\u0435\u0440\u0432\u0435\u0440\u0435. \u0415\u0433\u043e \u043d\u0435\u043b\u044c\u0437\u044f \u0440\u0430\u0437\u0434\u0435\u043b\u044f\u0442\u044c \u043c\u0435\u0436\u0434\u0443 \u043d\u0435\u0441\u043a\u043e\u043b\u044c\u043a\u0438\u043c\u0438 control plane, \u0440\u0435\u043f\u043b\u0438\u043a\u0430\u0446\u0438\u0438 \u043d\u0435\u0442. \u041f\u043e\u0437\u0436\u0435 \u043c\u043e\u0436\u043d\u043e \u043f\u0435\u0440\u0435\u0439\u0442\u0438 \u043d\u0430 PostgreSQL: toutwaf-cp db migrate.'
        'db_q_host' = '\u0425\u043e\u0441\u0442 PostgreSQL'
        'db_q_port' = '\u041f\u043e\u0440\u0442'
        'db_q_name' = '\u0418\u043c\u044f \u0431\u0430\u0437\u044b \u0434\u0430\u043d\u043d\u044b\u0445'
        'db_q_user' = '\u041f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044c \u0431\u0430\u0437\u044b \u0434\u0430\u043d\u043d\u044b\u0445'
        'db_q_pw' = '\u041f\u0430\u0440\u043e\u043b\u044c \u044d\u0442\u043e\u0433\u043e \u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044f (\u043f\u0443\u0441\u0442\u043e, \u0435\u0441\u043b\u0438 \u0435\u0433\u043e \u0441\u043e\u0437\u0434\u0430\u0451\u0442 \u0443\u0447\u0451\u0442\u043d\u0430\u044f \u0437\u0430\u043f\u0438\u0441\u044c \u0430\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430)'
        'db_q_tls' = '\u0420\u0435\u0436\u0438\u043c TLS (disable, prefer, require, verify-ca, verify-full)'
        'db_q_ca' = '\u0424\u0430\u0439\u043b \u0441\u0435\u0440\u0442\u0438\u0444\u0438\u043a\u0430\u0442\u0430 \u0426\u0421 \u0441\u0435\u0440\u0432\u0435\u0440\u0430 (\u0434\u043b\u044f verify-ca / verify-full)'
        'db_q_admin' = '\u0423\u0447\u0451\u0442\u043d\u0430\u044f \u0437\u0430\u043f\u0438\u0441\u044c \u0430\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430, \u0441\u043e\u0437\u0434\u0430\u044e\u0449\u0430\u044f \u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044f \u0438 \u0431\u0430\u0437\u0443 (\u043f\u0443\u0441\u0442\u043e = \u0443\u0436\u0435 \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0442)'
        'db_q_adminpw' = '\u041f\u0430\u0440\u043e\u043b\u044c \u0430\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430 (\u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0435\u0442\u0441\u044f \u043e\u0434\u0438\u043d \u0440\u0430\u0437, \u043d\u0435 \u0441\u043e\u0445\u0440\u0430\u043d\u044f\u0435\u0442\u0441\u044f)'
        'db_hint' = '\u0411\u0430\u0437\u0430 \u0434\u0430\u043d\u043d\u044b\u0445: SQLite (\u043f\u043e \u0443\u043c\u043e\u043b\u0447\u0430\u043d\u0438\u044e). \u0414\u043b\u044f \u0441\u0435\u0440\u0432\u0435\u0440\u043d\u043e\u0439 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0438 \u0438\u043b\u0438 \u043d\u0435\u0441\u043a\u043e\u043b\u044c\u043a\u0438\u0445 control plane \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0439\u0442\u0435 --db postgres (--db-install-local \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442 \u0435\u0451).'
        'db_no_pkg' = 'PostgreSQL \u043d\u0435\u043b\u044c\u0437\u044f \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c \u0430\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u0438 \u0432 \u044d\u0442\u043e\u0439 \u0441\u0438\u0441\u0442\u0435\u043c\u0435: \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0435 \u0441\u0435\u0440\u0432\u0435\u0440\u043d\u044b\u0439 \u043f\u0430\u043a\u0435\u0442 \u0441\u0430\u043c\u0438 \u0438 \u0441\u043d\u043e\u0432\u0430 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a \u0441 --db postgres.'
        'db_install_failed' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c \u043f\u0430\u043a\u0435\u0442 PostgreSQL. \u041f\u0440\u0438\u0447\u0438\u043d\u0430 \u2014 \u0432 \u0436\u0443\u0440\u043d\u0430\u043b\u0435 (/var/log/toutwaf-install.log).'
        'db_init_failed' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0438\u043d\u0438\u0446\u0438\u0430\u043b\u0438\u0437\u0438\u0440\u043e\u0432\u0430\u0442\u044c \u043a\u043b\u0430\u0441\u0442\u0435\u0440 PostgreSQL. \u041f\u0440\u0438\u0447\u0438\u043d\u0430 \u2014 \u0432 \u0436\u0443\u0440\u043d\u0430\u043b\u0435.'
        'db_start_failed' = 'PostgreSQL \u043d\u0435 \u0437\u0430\u043f\u0443\u0441\u043a\u0430\u0435\u0442\u0441\u044f. \u041f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435: systemctl status postgresql \u0438 \u0436\u0443\u0440\u043d\u0430\u043b.'
        'db_too_old' = '\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043d\u0430\u044f \u0432\u0435\u0440\u0441\u0438\u044f PostgreSQL ({0}) \u0441\u043b\u0438\u0448\u043a\u043e\u043c \u0441\u0442\u0430\u0440\u0430\u044f: \u043d\u0443\u0436\u043d\u0430 \u0432\u0435\u0440\u0441\u0438\u044f 13 \u0438\u043b\u0438 \u043d\u043e\u0432\u0435\u0435.'
        'db_exists' = '\u041f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044c "{0}" \u0438\u043b\u0438 \u0431\u0430\u0437\u0430 "{1}" \u0443\u0436\u0435 \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u0435\u0442 \u0438 \u0441\u043e\u0437\u0434\u0430\u043d\u0430 \u043d\u0435 \u044d\u0442\u0438\u043c \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a\u043e\u043c: \u043d\u0438\u0447\u0435\u0433\u043e \u043d\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u043e. \u0412\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u0434\u0440\u0443\u0433\u0438\u0435 \u0438\u043c\u0435\u043d\u0430 (--db-name, --db-user) \u0438\u043b\u0438 \u0443\u043a\u0430\u0436\u0438\u0442\u0435 \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0449\u0435\u0435 \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0435 (--db-dsn-file).'
        'db_create_failed' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0441\u043e\u0437\u0434\u0430\u0442\u044c \u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044f \u0438\u043b\u0438 \u0431\u0430\u0437\u0443. \u0421\u043e\u0437\u0434\u0430\u043d\u043d\u043e\u0435 \u0443\u0434\u0430\u043b\u0435\u043d\u043e.'
        'db_rights' = '\u0423 \u0443\u0447\u0451\u0442\u043d\u043e\u0439 \u0437\u0430\u043f\u0438\u0441\u0438 \u043d\u0435\u0442 \u043f\u0440\u0430\u0432. \u041a\u043e\u043c\u0430\u043d\u0434\u044b \u0432\u044b\u0448\u0435 \u2014 \u043c\u0438\u043d\u0438\u043c\u0443\u043c, \u043a\u043e\u0442\u043e\u0440\u044b\u0439 \u0434\u043e\u043b\u0436\u0435\u043d \u0432\u044b\u043f\u043e\u043b\u043d\u0438\u0442\u044c \u0430\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440 \u0441\u0435\u0440\u0432\u0435\u0440\u0430; \u0437\u0430\u0442\u0435\u043c \u0441\u043d\u043e\u0432\u0430 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0449\u0438\u043a.'
        'db_need_conn' = '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0435 \u043a \u0441\u0435\u0440\u0432\u0435\u0440\u0443 PostgreSQL \u043d\u0435 \u0437\u0430\u0434\u0430\u043d\u043e: \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0439\u0442\u0435 --db-dsn-file, \u043b\u0438\u0431\u043e --db-host \u0441 --db-password-file, \u043b\u0438\u0431\u043e --db-install-local.'
        'db_schema_failed' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0441\u043e\u0437\u0434\u0430\u0442\u044c \u0442\u0430\u0431\u043b\u0438\u0446\u044b \u0432 \u0431\u0430\u0437\u0435. \u041f\u0440\u0438\u0447\u0438\u043d\u0430 \u2014 \u0432 \u0436\u0443\u0440\u043d\u0430\u043b\u0435.'
        'db_no_pgdump' = 'pg_dump \u043e\u0442\u0441\u0443\u0442\u0441\u0442\u0432\u0443\u0435\u0442: \u0435\u0436\u0435\u0434\u043d\u0435\u0432\u043d\u0430\u044f \u043a\u043e\u043f\u0438\u044f \u0431\u0430\u0437\u044b \u0431\u0443\u0434\u0435\u0442 \u0432\u044b\u0434\u0430\u0432\u0430\u0442\u044c \u043e\u0448\u0438\u0431\u043a\u0443, \u043f\u043e\u043a\u0430 \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d \u043a\u043b\u0438\u0435\u043d\u0442\u0441\u043a\u0438\u0439 \u043f\u0430\u043a\u0435\u0442 PostgreSQL.'
        'db_sum_engine' = '\u0411\u0430\u0437\u0430 \u0434\u0430\u043d\u043d\u044b\u0445: {0}'
        'db_sum_local' = 'PostgreSQL \u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442 \u043d\u0430 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435 (\u0442\u043e\u043b\u044c\u043a\u043e loopback); \u0431\u0430\u0437\u0430 {0}, \u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044c {1} (\u0431\u0435\u0437 \u043f\u0440\u0430\u0432 \u0430\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430)'
        'db_sum_remote' = '\u0421\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0449\u0438\u0439 \u0441\u0435\u0440\u0432\u0435\u0440 PostgreSQL; \u0431\u0430\u0437\u0430 {0}, \u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044c {1}'
        'db_sum_schema' = '\u0421\u0445\u0435\u043c\u0430: {0}'
        'db_sum_secret' = '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0435 (\u0441 \u043f\u0430\u0440\u043e\u043b\u0435\u043c) \u0445\u0440\u0430\u043d\u0438\u0442\u0441\u044f \u0432 {0} \u0438 \u0447\u0438\u0442\u0430\u0435\u0442\u0441\u044f \u0442\u043e\u043b\u044c\u043a\u043e \u0441\u043b\u0443\u0436\u0431\u043e\u0439 ToutWAF'
        'db_sum_backup' = '\u041a\u0430\u0436\u0434\u0443\u044e \u043d\u043e\u0447\u044c \u0432\u044b\u043f\u043e\u043b\u043d\u044f\u0435\u0442\u0441\u044f \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u043d\u044b\u0439 pg_dump (\u0445\u0440\u0430\u043d\u0438\u0442\u0441\u044f 7); \u0441\u043e\u0441\u0442\u043e\u044f\u043d\u0438\u0435 \u0432 \u043a\u043e\u043d\u0441\u043e\u043b\u0438, Sant\u00e9'
        'db_sum_nobackup' = '\u0410\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u043e\u0439 \u043a\u043e\u043f\u0438\u0438 \u0431\u0430\u0437\u044b \u043d\u0435\u0442: \u0437\u0430\u043f\u043b\u0430\u043d\u0438\u0440\u0443\u0439\u0442\u0435 pg_dump \u0438\u043b\u0438 \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0439\u0442\u0435 \u043a\u043e\u043f\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u0435 \u0432\u0430\u0448\u0435\u0433\u043e \u043f\u043e\u0441\u0442\u0430\u0432\u0449\u0438\u043a\u0430 \u0411\u0414'
        'db_sum_sqlite' = '\u0411\u0430\u0437\u0430 \u0434\u0430\u043d\u043d\u044b\u0445: SQLite, \u043e\u0434\u0438\u043d \u0444\u0430\u0439\u043b \u043d\u0430 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435 (\u043d\u0435\u0431\u043e\u043b\u044c\u0448\u0430\u044f \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430). \u041f\u043e\u0437\u0436\u0435 \u043f\u0435\u0440\u0435\u0439\u0442\u0438 \u043d\u0430 PostgreSQL: toutwaf-cp db migrate'
        's_extras' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f: \u0430\u0433\u0435\u043d\u0442 \u0434\u043b\u044f Windows \u0438 \u043f\u0440\u043e\u0433\u0440\u0430\u043c\u043c\u044b \u0430\u043d\u0442\u0438\u0432\u0438\u0440\u0443\u0441\u0430'
        's_extras_ok' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u044b: {0} \u043f\u0440\u043e\u0433\u0440\u0430\u043c\u043c \u0432 {1}'
        's_extras_sha' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f \u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u044b: \u0444\u0430\u0439\u043b\u043e\u0432 {0}, {1} \u041c\u0438\u0411 (SHA-256 \u0438 \u043f\u043e\u0434\u043f\u0438\u0441\u044c)'
        's_extras_unchecked' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f \u0432\u0437\u044f\u0442\u044b \u043a\u0430\u043a \u0435\u0441\u0442\u044c, \u0431\u0435\u0437 SHA256SUMS \u0434\u043b\u044f \u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0438: {0}'
        'w_extras_dl' = '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0437\u0430\u0433\u0440\u0443\u0437\u0438\u0442\u044c \u0434\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f ({0}). ToutWAF \u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442 \u0431\u0435\u0437 \u043d\u0438\u0445, \u043d\u043e \u044d\u0442\u0430 \u043a\u043e\u043d\u0441\u043e\u043b\u044c \u043d\u0435 \u043f\u0440\u0435\u0434\u043b\u043e\u0436\u0438\u0442 Windows \u0438 \u0430\u043d\u0442\u0438\u0432\u0438\u0440\u0443\u0441, \u043f\u043e\u043a\u0430 \u043e\u043d\u0438 \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u044b.'
        'w_extras_sum' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f {0} \u043d\u0435 \u0441\u043e\u0432\u043f\u0430\u0434\u0430\u044e\u0442 \u0441\u043e \u0441\u0432\u043e\u0435\u0439 \u0441\u0443\u043c\u043c\u043e\u0439 SHA-256 \u0432 \u043f\u043e\u0434\u043f\u0438\u0441\u0430\u043d\u043d\u043e\u043c SHA256SUMS: \u043e\u043d\u0438 \u041d\u0415 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u044b.'
        'w_extras_bad' = '\u0424\u0430\u0439\u043b \u0434\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u0439 {0} \u043d\u0435 \u044f\u0432\u043b\u044f\u0435\u0442\u0441\u044f \u0434\u043e\u043f\u0443\u0441\u0442\u0438\u043c\u044b\u043c \u0430\u0440\u0445\u0438\u0432\u043e\u043c \u0434\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u0439: \u043e\u043d \u041d\u0415 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d.'
        'w_extras_ver' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f \u043e\u0442 \u0432\u0435\u0440\u0441\u0438\u0438 {0}, \u0430 \u044d\u0442\u0430 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u2014 {1}: \u043e\u043d\u0438 \u041d\u0415 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u044b.'
        'w_extras_inc' = '\u0420\u0435\u043b\u0438\u0437 \u043f\u0435\u0440\u0435\u0447\u0438\u0441\u043b\u044f\u0435\u0442 {0} \u0447\u0430\u0441\u0442\u0435\u0439 \u0434\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u0439, \u043d\u043e \u0437\u0430\u044f\u0432\u043b\u044f\u0435\u0442 {1}: \u043f\u0443\u0431\u043b\u0438\u043a\u0430\u0446\u0438\u044f \u043f\u043e\u0432\u0440\u0435\u0436\u0434\u0435\u043d\u0430, \u0434\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f \u041d\u0415 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u044b.'
        'w_extras_nofile' = '\u0424\u0430\u0439\u043b \u0434\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u0439 {0} \u043d\u0435 \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u0435\u0442.'
        'w_extras_none' = '\u0412 \u044d\u0442\u043e\u043c \u0440\u0435\u043b\u0438\u0437\u0435 \u043d\u0435\u0442 \u0434\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u0439: \u044d\u0442\u0430 \u043a\u043e\u043d\u0441\u043e\u043b\u044c \u043d\u0435 \u043f\u0440\u0435\u0434\u043b\u043e\u0436\u0438\u0442 Windows \u0438 \u0430\u043d\u0442\u0438\u0432\u0438\u0440\u0443\u0441.'
        'w_extras_todo' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u044b. \u041a\u043e\u0433\u0434\u0430 \u0441\u0435\u0442\u044c \u043f\u043e\u0437\u0432\u043e\u043b\u0438\u0442, \u0432\u044b\u043f\u043e\u043b\u043d\u0438\u0442\u0435 \u043e\u0442 root: {0}'
        'extras_needs_cp' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f \u043e\u0442\u043d\u043e\u0441\u044f\u0442\u0441\u044f \u043a control plane: \u043e\u043d \u043d\u0435 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d \u043d\u0430 \u044d\u0442\u043e\u0439 \u043c\u0430\u0448\u0438\u043d\u0435.'
        'extras_other_release' = '\u041e\u043f\u0443\u0431\u043b\u0438\u043a\u043e\u0432\u0430\u043d\u043d\u044b\u0439 \u0440\u0435\u043b\u0438\u0437 ({0}) \u043d\u0435 \u0441\u043e\u0432\u043f\u0430\u0434\u0430\u0435\u0442 \u0441 \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043d\u044b\u043c ({1}): \u0434\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f \u0438\u0434\u0443\u0442 \u0432\u043c\u0435\u0441\u0442\u0435 \u0441 \u043d\u0438\u043c. \u0412\u044b\u043f\u043e\u043b\u043d\u0438\u0442\u0435 --update.'
        'st_extras_ok' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f: \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u044b (\u0430\u0433\u0435\u043d\u0442 \u0434\u043b\u044f Windows, \u043f\u0440\u043e\u0433\u0440\u0430\u043c\u043c\u044b \u0430\u043d\u0442\u0438\u0432\u0438\u0440\u0443\u0441\u0430)'
        'st_extras_none' = '\u0414\u043e\u043f\u043e\u043b\u043d\u0435\u043d\u0438\u044f \u043e\u0442\u0441\u0443\u0442\u0441\u0442\u0432\u0443\u044e\u0442: Windows \u0438 \u0430\u043d\u0442\u0438\u0432\u0438\u0440\u0443\u0441 \u043d\u0435 \u043f\u0440\u0435\u0434\u043b\u0430\u0433\u0430\u044e\u0442\u0441\u044f. \u0412\u044b\u043f\u043e\u043b\u043d\u0438\u0442\u0435 \u043e\u0442 root: {0}'
    }
    'zh' = @{
        'tagline' = 'Web \u5e94\u7528\u4e0e API \u9632\u62a4'
        'menu_title' = '\u8bf7\u9009\u62e9\u8981\u6267\u884c\u7684\u64cd\u4f5c'
        'opt_install' = '\u5b89\u88c5\uff08\u63a7\u5236\u5e73\u9762 + \u6570\u636e\u5e73\u9762 + \u63a7\u5236\u53f0\uff09'
        'opt_install_d' = '\u5728\u672c\u673a\u5b89\u88c5\u5168\u90e8\u7ec4\u4ef6\uff1aWeb \u63a7\u5236\u53f0\u3001\u7b56\u7565\u5e93\u548c\u53cd\u5411\u4ee3\u7406 / WAF\u3002'
        'opt_cp' = '\u4ec5\u5b89\u88c5\u63a7\u5236\u5e73\u9762'
        'opt_cp_d' = 'Web \u63a7\u5236\u53f0\u3001API \u4e0e\u7b56\u7565\u5e93\u3002\u6570\u636e\u5e73\u9762\uff08\u8282\u70b9\uff09\u7a0d\u540e\u52a0\u5165\u3002'
        'opt_dp' = '\u4ec5\u5b89\u88c5\u6570\u636e\u5e73\u9762'
        'opt_dp_d' = '\u52a0\u5165\u73b0\u6709\u63a7\u5236\u5e73\u9762\u7684\u53cd\u5411\u4ee3\u7406 / WAF \u8282\u70b9\uff08\u9700\u8981\u5176 URL \u548c\u6ce8\u518c\u4ee4\u724c\uff09\u3002'
        'opt_update' = '\u66f4\u65b0'
        'opt_update_d' = '\u4e0b\u8f7d\u65b0\u7248\u672c\uff0c\u6821\u9a8c\uff08SHA-256 / sigstore\uff09\uff0c\u5148\u5907\u4efd\uff0c\u4fdd\u7559\u914d\u7f6e\u548c\u6570\u636e\uff0c\u5931\u8d25\u65f6\u56de\u6eda\u3002'
        'opt_uninstall' = '\u5378\u8f7d'
        'opt_uninstall_d' = '\u79fb\u9664 ToutWAF\uff1b\u53ef\u9009\u62e9\u4fdd\u7559\u6216\u5220\u9664\u914d\u7f6e\u3001\u6570\u636e\u548c\u65e5\u5fd7\u3002'
        'opt_status' = '\u72b6\u6001\u4e0e\u5065\u5eb7\u68c0\u67e5'
        'opt_status_d' = '\u5df2\u5b89\u88c5\u7248\u672c\u3001\u670d\u52a1\u3001\u76d1\u542c\u7aef\u53e3\u548c\u5065\u5eb7\u68c0\u67e5\u7aef\u70b9\u3002'
        'opt_links' = '\u518d\u6b21\u663e\u793a\u9762\u677f\u94fe\u63a5'
        'opt_links_d' = '\u9762\u677f\u5730\u5740\u3001\u4e00\u6b21\u6027\u8bbe\u7f6e\u94fe\u63a5\u4ee5\u53ca\u9700\u8981\u5728\u9632\u706b\u5899\u653e\u884c\u7684\u7aef\u53e3\u3002'
        'opt_quit' = '\u9000\u51fa'
        'choice' = '\u60a8\u7684\u9009\u62e9'
        'invalid_choice' = '\u65e0\u6548\u7684\u9009\u62e9\u3002'
        'state_installed' = '\u5df2\u5b89\u88c5\uff1a{0}'
        'state_none' = '\u672c\u673a\u5c1a\u672a\u5b89\u88c5 ToutWAF\u3002'
        'cfg_title' = '\u5b89\u88c5\u9009\u9879\uff08\u56de\u8f66 = \u9ed8\u8ba4\u503c\uff09'
        'q_cp_url' = '\u63a7\u5236\u5e73\u9762 URL\uff08\u4f8b\u5982 https://cp.example.com:9444\uff09'
        'q_token' = '\u6ce8\u518c\u4ee4\u724c\uff08\u63a7\u5236\u53f0\uff1a\u8282\u70b9 > \u6dfb\u52a0\u8282\u70b9\uff09'
        'q_cp_ca' = '\u63a7\u5236\u5e73\u9762 CA / \u8bc1\u4e66 PEM \u6587\u4ef6\uff08\u7559\u7a7a = \u7cfb\u7edf\u4fe1\u4efb\u5e93\uff09'
        'q_cp_port' = '\u63a7\u5236\u53f0\u7aef\u53e3'
        'q_http_port' = 'HTTP \u7aef\u53e3'
        'q_https_port' = 'HTTPS \u7aef\u53e3'
        'q_public_host' = '\u516c\u7f51\u4e3b\u673a\u540d\u6216 IP \u5730\u5740\uff08\u7559\u7a7a = \u81ea\u52a8\u68c0\u6d4b\uff09'
        'q_firewall' = '\u662f\u5426\u81ea\u52a8\u653e\u884c\u9632\u706b\u5899\u7aef\u53e3\uff08firewalld / ufw\uff09\uff1f'
        'q_boot' = '\u662f\u5426\u5f00\u673a\u81ea\u52a8\u542f\u52a8\u670d\u52a1\uff1f'
        'q_channel' = '\u53d1\u5e03\u901a\u9053\uff08stable / dev\uff09'
        'q_bindir' = '\u5b89\u88c5\u76ee\u5f55'
        'q_confirm' = '\u5f00\u59cb\u5b89\u88c5\uff1f'
        'q_purge' = '\u540c\u65f6\u5220\u9664\u914d\u7f6e\u3001\u6570\u636e\u548c\u65e5\u5fd7\uff1f\uff08\u5426 = \u4fdd\u7559\uff09'
        'q_confirm_un' = '\u786e\u5b9a\u8981\u5378\u8f7d ToutWAF \u5417\uff1f'
        'aborted' = '\u5df2\u53d6\u6d88\u3002'
        'root_required' = '\u8bf7\u4ee5 root \u8eab\u4efd\u8fd0\u884c\uff08sudo bash install.sh\uff09\u3002'
        's_prereq' = '\u5b89\u88c5\u4f9d\u8d56\u9879'
        's_fetch' = '\u6b63\u5728\u4e0b\u8f7d ToutWAF {0}\uff08{1}\uff09'
        's_sha' = 'SHA-256 \u6821\u9a8c\u901a\u8fc7'
        's_sig' = 'cosign \u7b7e\u540d\u6821\u9a8c\u901a\u8fc7'
        'w_nocosign' = '\u672a\u5b89\u88c5 cosign\uff1a\u672a\u6821\u9a8c\u7b7e\u540d\uff08\u4ec5\u6821\u9a8c\u548c\uff09'
        's_user' = '\u521b\u5efa\u670d\u52a1\u8d26\u6237\u548c\u76ee\u5f55'
        's_bin' = '\u5b89\u88c5\u7a0b\u5e8f\u6587\u4ef6'
        's_cfg' = '\u5199\u5165\u914d\u7f6e\uff08\u4fdd\u7559\u5df2\u6709\u6587\u4ef6\uff09'
        's_units' = '\u5b89\u88c5 systemd \u5355\u5143\u4e0e\u7cfb\u7edf\u8c03\u4f18'
        's_selinux' = '\u914d\u7f6e SELinux'
        'q_console_from' = '\u4ec5\u5141\u8bb8\u8be5\u7f51\u7edc\u8bbf\u95ee\u63a7\u5236\u53f0\uff08CIDR\uff0c\u5982 203.0.113.0/24\uff1b\u7559\u7a7a = \u4efb\u4f55\u4eba\uff09'
        'q_console_from_bad' = '\u4e0d\u662f\u6709\u6548\u7684\u5730\u5740\u6216 CIDR\uff080.0.0.0/0 \u7b49\u540c\u4e8e\u7559\u7a7a\uff09\uff1a\u63a7\u5236\u53f0\u7aef\u53e3\u5bf9\u6240\u6709\u4eba\u5f00\u653e\u3002'
        'fw_console_note' = '\u63a7\u5236\u53f0\uff08\u7aef\u53e3 {0}\uff09\u627f\u8f7d\u7ba1\u7406\u5458\u767b\u5f55\uff1a\u5411\u6574\u4e2a\u4e92\u8054\u7f51\u5f00\u653e\u867d\u7136\u65b9\u4fbf\uff0c\u4f46\u5b58\u5728\u66b4\u9732\u98ce\u9669\u3002'
        'fw_console_open' = '\u63a7\u5236\u53f0\u7aef\u53e3 {0} \u5bf9\u6240\u6709\u4eba\u5f00\u653e\uff1a\u8bf7\u7528 --console-from CIDR \u6216\u5728\u63a7\u5236\u53f0\uff08\u8bbe\u7f6e > \u9632\u706b\u5899\uff09\u4e2d\u9650\u5236'
        'fw_console_from' = '\u63a7\u5236\u53f0\u7aef\u53e3 {0} \u4ec5\u5bf9 {1} \u5f00\u653e'
        'fw_none' = '\u672a\u53d1\u73b0\u6d3b\u52a8\u7684\u9632\u706b\u5899\uff08firewalld / ufw / nftables / iptables\uff09\uff1a\u6d41\u91cf\u672a\u88ab\u8fc7\u6ee4\uff0c\u65e0\u9700\u653e\u884c\u7aef\u53e3'
        'fw_manual' = '\u5b89\u88c5\u7a0b\u5e8f\u4e0d\u4f1a\u4fee\u6539 {0} \u9632\u706b\u5899\uff1a\u8bf7\u81ea\u884c\u6267\u884c\u4ee5\u4e0b\u547d\u4ee4'
        'fw_failed' = '\u65e0\u6cd5\u914d\u7f6e\u9632\u706b\u5899\uff1a{0}'
        'home_fresh' = '\u5168\u65b0\u5b89\u88c5\uff1a\u6240\u6709\u5185\u5bb9\u4f4d\u4e8e {0}\uff08bin\u3001conf\u3001data\u3001logs\uff09'
        'home_legacy' = '\u68c0\u6d4b\u5230\u73b0\u6709\u5b89\u88c5\uff1a\u6cbf\u7528\u5176\u8def\u5f84\uff08bin {0}\u3001conf {1}\u3001data {2}\uff09\u3002\u4e0d\u4f1a\u79fb\u52a8\u4efb\u4f55\u5185\u5bb9\uff1b\u4f7f\u7528 --home DIR \u91c7\u7528\u65b0\u5e03\u5c40\u3002'
        'home_explicit_legacy' = '\u5df2\u6307\u5b9a --home {0}\uff0c\u4f46 {1} \u4e2d\u5df2\u6709\u5b89\u88c5\uff1a\u5176\u6570\u636e\u4e0d\u4f1a\u88ab\u79fb\u52a8'
        'home_bad' = '--home \u5fc5\u987b\u662f\u7edd\u5bf9\u8def\u5f84\uff08\u5b57\u6bcd\u3001\u6570\u5b57\u3001. _ - + /\uff09\uff0c\u4e0d\u80fd\u662f / \u4e5f\u4e0d\u80fd\u4f4d\u4e8e /proc /sys /dev \u4e0b\uff1a{0}'
        'home_noexec' = '{0} \u4f4d\u4e8e noexec \u6302\u8f7d\u4e0a\uff1a\u4e8c\u8fdb\u5236\u6587\u4ef6\u65e0\u6cd5\u5728\u6b64\u8fd0\u884c\uff0c\u8bf7\u9009\u62e9\u5176\u4ed6 --home'
        's_fw' = '\u914d\u7f6e\u9632\u706b\u5899'
        's_boot' = '\u51c6\u5907\u9762\u677f\uff08\u7ba1\u7406\u5458\u8d26\u6237\u3001\u5b89\u5168\u8def\u5f84\uff09'
        's_start' = '\u542f\u52a8\u670d\u52a1'
        's_health' = '\u7b49\u5f85\u670d\u52a1\u5c31\u7eea'
        's_backup' = '\u5907\u4efd\u914d\u7f6e\u4e0e\u6570\u636e'
        'w_rollback' = '\u65b0\u7248\u672c\u8fd0\u884c\u5f02\u5e38\uff1a\u6b63\u5728\u56de\u6eda\u5230\u4e0a\u4e00\u7248\u672c'
        'up_to_date' = '\u5df2\u662f\u6700\u65b0\u7248\u672c\uff08{0}\uff09'
        'not_installed' = '\u5c1a\u672a\u5b89\u88c5 ToutWAF\uff1a\u65e0\u9700\u66f4\u65b0\u3002'
        'st_channel' = '\u901a\u9053\uff1a{0}'
        'st_latest' = '\u6700\u65b0\u53ef\u7528\u7248\u672c\uff1a{0}'
        'st_newer' = '\u6709\u53ef\u7528\u66f4\u65b0\uff1a\u8bf7\u4f7f\u7528 --update \u8fd0\u884c'
        'e_yanked' = '\u7248\u672c {0} \u5df2\u88ab\u64a4\u56de\uff08yanked\uff09\uff0c\u4e0d\u5e94\u5b89\u88c5\u3002\u8bf7\u8fd0\u884c --update \u83b7\u53d6\u5f53\u524d\u7248\u672c\uff0c\u6216\u4f7f\u7528 --force \u5f3a\u5236\u3002'
        'e_nover' = '{0} \u901a\u9053\u5c1a\u672a\u53d1\u5e03\u4efb\u4f55\u7248\u672c\uff0c\u56e0\u6b64\u6ca1\u6709\u53ef\u5b89\u88c5\u7684\u5185\u5bb9\u3002\u672a\u5b89\u88c5\u6216\u66f4\u6539 ToutWAF\u3002\u82e5\u8981\u6539\u4ece {1} \u901a\u9053\u5b89\u88c5\uff0c\u8bf7\u4f7f\u7528 -Channel {2} \u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'e_installer_old' = '\u6b64\u5b89\u88c5\u7a0b\u5e8f\u5bf9\u8be5\u7248\u672c\u800c\u8a00\u592a\u65e7\uff08\u9700\u8981\u7248\u672c {0}\uff09\uff1a\u8bf7\u4ece\u901a\u9053 URL \u91cd\u65b0\u4e0b\u8f7d\u3002'
        'up_rebuilt' = '\u7248\u672c\u76f8\u540c\uff0c\u6709\u65b0\u6784\u5efa\uff1a\u5df2\u5b89\u88c5 {0}\uff0c\u53ef\u7528 {1}\u3002\u6b63\u5728\u66f4\u65b0\u3002'
        'st_newbuild' = '\u7248\u672c\u76f8\u540c\uff0c\u6709\u65b0\u6784\u5efa\uff1a\u8bf7\u4f7f\u7528 {0} \u518d\u6b21\u8fd0\u884c'
        'st_nochannel' = '\u6700\u65b0\u53ef\u7528\u7248\u672c\uff1a\u6b64\u6e20\u9053\u5c1a\u672a\u53d1\u5e03\u4efb\u4f55\u5185\u5bb9'
        'w_mirror' = '\u516c\u5171\u955c\u50cf\u63d0\u4f9b\u7684\u6587\u4ef6\u5f7c\u6b64\u4e0d\u4e00\u81f4\uff08{0}\uff09\uff1a\u5f88\u53ef\u80fd\u662f\u53d1\u5e03\u540e\u4ecd\u5728\u5237\u65b0\u3002\u5c06\u91cd\u65b0\u8bfb\u53d6\u4e00\u6b21\u6e20\u9053\u3002'
        'e_mismatch' = '{0} \u7684\u6821\u9a8c\u548c\u4e0d\u5339\u914d\uff08{1}\uff09\uff1a\u4e0b\u8f7d\u7684\u6587\u4ef6\u4e0e\u5df2\u53d1\u5e03\u7684\u6821\u9a8c\u548c\u4e0d\u4e00\u81f4\uff0c\u56e0\u6b64\u672a\u5b89\u88c5\u6216\u66f4\u6539\u4efb\u4f55\u5185\u5bb9\u3002\u53d1\u5e03\u540e\u7684\u51e0\u5206\u949f\u5185\uff0c\u516c\u5171\u955c\u50cf\u53ef\u80fd\u4ecd\u63d0\u4f9b\u65e7\u6587\u4ef6\uff1a\u8bf7\u7b49\u5f85\u4e94\u5206\u949f\u540e\u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002\u82e5\u518d\u6b21\u51fa\u73b0\uff0c\u8bf7\u52ff\u5b89\u88c5\uff1a\u8be5\u53d1\u5e03\u5df2\u635f\u574f\u3002'
        'e_downgrade' = '\u6700\u65b0\u7248\u672c {0}\uff08\u901a\u9053 {1}\uff09\u6bd4\u5df2\u5b89\u88c5\u7684 {2} \u65e7\uff1a\u4f7f\u7528 --force \u964d\u7ea7\u3002'
        's_sigok' = '\u53d1\u5e03\u7b7e\u540d\u6821\u9a8c\u901a\u8fc7\uff0c\u5bc6\u94a5 {0}'
        'w_sigold' = '\u7248\u672c {0} \u53d1\u5e03\u65f6\u6ca1\u6709\u7b7e\u540d\uff080.2.0-dev.7 \u4e4b\u524d\u7684\u7248\u672c\u5747\u672a\u7b7e\u540d\uff09\uff1a\u4ec5\u6821\u9a8c\u4e86 SHA-256\uff0c\u65e0\u6cd5\u6821\u9a8c\u7b7e\u540d'
        'w_sigskip' = '\u672a\u6821\u9a8c\u53d1\u5e03\u7b7e\u540d\uff1aPATH \u4e2d\u627e\u4e0d\u5230 openssl.exe\uff08Windows \u6ca1\u6709\u5185\u7f6e Ed25519 \u6821\u9a8c\uff09\uff0c\u4ec5\u6821\u9a8c\u4e86 SHA-256\u3002\u8bf7\u5b89\u88c5 OpenSSL 3 \u5e76\u91cd\u65b0\u8fd0\u884c\uff0c\u4ee5\u4f7f\u7528\u5bc6\u94a5 {0} \u6821\u9a8c'
        'done' = '\u5b8c\u6210\u3002'
        'failed' = '\u5931\u8d25'
        'log_hint' = '\u5b8c\u6574\u65e5\u5fd7\uff1a{0}'
        'dry_done' = '\u8bd5\u8fd0\u884c\uff1a\u672a\u505a\u4efb\u4f55\u66f4\u6539\u3002'
        'sum_title' = '\u5b89\u88c5\u6458\u8981'
        'sum_panel' = '\u9762\u677f\u94fe\u63a5'
        'sum_tls_note' = '\u4ec5 HTTPS\u3002\u5728\u5b89\u88c5\u60a8\u81ea\u5df1\u7684\u8bc1\u4e66\u4e4b\u524d\u4f7f\u7528\u81ea\u7b7e\u540d\u8bc1\u4e66\uff1a\u6d4f\u89c8\u5668\u4f1a\u663e\u793a\u8b66\u544a\u3002'
        'sum_local' = '\u672c\u5730\u5730\u5740'
        'sum_public' = '\u516c\u7f51\u5730\u5740'
        'sum_public_unknown' = '\u65e0\u6cd5\u68c0\u6d4b\u516c\u7f51 IP\uff08\u79bb\u7ebf\u6216\u88ab\u62e6\u622a\uff09\u3002\u8bf7\u4f7f\u7528\u670d\u52a1\u5668\u7684\u516c\u7f51 IP \u6216\u57df\u540d\u4ee3\u66ff\u672c\u5730\u5730\u5740\uff0c\u6216\u4f7f\u7528 --public-host \u91cd\u65b0\u8fd0\u884c\u3002'
        'sum_admin' = '\u7ba1\u7406\u5458\u8d26\u6237'
        'sum_user' = '\u7528\u6237\u540d'
        'sum_password' = '\u5bc6\u7801'
        'sum_pw_once' = '\u4ec5\u663e\u793a\u4e00\u6b21 - \u53ef\u5728 \u8bbe\u7f6e > \u8bbf\u95ee / \u8d26\u6237 \u4e2d\u4fee\u6539'
        'sum_pw_unchanged' = '\u4fdd\u6301\u4e0d\u53d8\uff08\u4e0d\u4f1a\u91cd\u65b0\u751f\u6210\uff09\u3002\u91cd\u7f6e\u547d\u4ee4\uff1atoutwaf-cp admin reset-password --user {0}'
        'sum_setup' = '\u4e00\u6b21\u6027\u8bbe\u7f6e\u94fe\u63a5'
        'sum_setup_note' = '\u6253\u5f00\u5b83\u5373\u53ef\u5728 Web \u5b89\u88c5\u5411\u5bfc\u4e2d\u8bbe\u7f6e\u9762\u677f\u94fe\u63a5\u3001\u8d26\u6237\u548c\u5bc6\u7801\u3002'
        'p_dpapi_warn' = '\u7aef\u53e3 9444\uff08\u6570\u636e\u5e73\u9762 API\uff09\u672a\u5f00\u653e\uff1a\u4ec5\u5141\u8bb8\u6765\u81ea\u60a8\u7684\u6570\u636e\u5e73\u9762\u8282\u70b9\u7684\u8bbf\u95ee'
        'p_dpapi_only' = '9444/tcp \u4ec5\u5141\u8bb8\u6765\u81ea\u60a8\u7684\u6570\u636e\u5e73\u9762\uff0c\u4f8b\u5982\uff1a'
        'sum_setup_none' = '\u672c\u6b21\u6ca1\u6709\u8bbe\u7f6e\u94fe\u63a5\uff08\u5df2\u7b7e\u53d1\uff0c\u6216\u8d26\u6237\u5df2\u5b58\u5728\uff09\u3002\u91cd\u65b0\u751f\u6210\uff1atoutwaf-cp setup-link --regenerate'
        'sum_ports' = '\u9700\u8981\u5728\u9632\u706b\u5899\u653e\u884c\u7684\u7aef\u53e3'
        'sum_cmds' = '\u547d\u4ee4'
        'sum_cloud' = '\u4e91\u670d\u52a1\u5668 / \u6258\u7ba1\uff1a\u8fd8\u9700\u5728\u670d\u52a1\u5546\u7684\u5b89\u5168\u7ec4 / \u7f51\u7edc ACL \u4e2d\u653e\u884c\u8fd9\u4e9b\u7aef\u53e3\u3002'
        'sum_file' = '\u6458\u8981\u5df2\u4fdd\u5b58\uff08\u4ec5 root \u53ef\u8bfb\uff09\uff1a{0}'
        'sum_fallback' = '\u8be5\u63a7\u5236\u5e73\u9762\u5c1a\u65e0 ''bootstrap'' \u547d\u4ee4\uff1a\u8bf7\u6253\u5f00\u63a7\u5236\u53f0\u5730\u5740\u5e76\u6309\u8bbe\u7f6e\u9875\u9762\u64cd\u4f5c\u3002'
        'sum_node_hint' = '\u8981\u5728\u63a7\u5236\u53f0\u7ba1\u7406\u6b64\u8282\u70b9\uff1a\u8282\u70b9 > \u6dfb\u52a0\u8282\u70b9\uff0c\u7136\u540e\u5728 {0} \u4e2d\u8bbe\u7f6e control_plane.url / enroll_token\u3002'
        'q_fwmodule' = '\u662f\u5426\u4e5f\u8ba9 ToutWAF \u7ba1\u7406\u672c\u673a\u7684\u9632\u706b\u5899\uff1f'
        'fwmod_n1' = '\u53ef\u9009\u6a21\u5757\uff0c\u9664\u975e\u56de\u7b54\u201c\u662f\u201d\u5426\u5219\u4fdd\u6301\u5173\u95ed\u3002\u5b89\u88c5\u671f\u95f4\u4e0d\u4f1a\u5e94\u7528\u4efb\u4f55\u89c4\u5219\uff1a\u6bcf\u9879\u66f4\u6539\u90fd\u5728\u63a7\u5236\u53f0\u4e2d\u5ba1\u6838\u3002'
        's_bkclient' = '\u6b63\u5728\u5b89\u88c5 ToutWAF Backup \u5ba2\u6237\u7aef\uff08\u5df2\u6821\u9a8c\u7b7e\u540d\uff09'
        'bkc_done' = 'ToutWAF Backup \u5ba2\u6237\u7aef\u5df2\u5b89\u88c5\u3002\u4e0b\u4e00\u6b65\uff1a\u63a7\u5236\u53f0\u201c\u5907\u4efd > \u5907\u4efd\u670d\u52a1\u5668\u201d\uff0c\u914d\u5bf9\u5907\u4efd\u670d\u52a1\u5668\u3002'
        'bkc_fail' = 'ToutWAF Backup \u5ba2\u6237\u7aef\u672a\u5b89\u88c5\uff08{0}\uff09\u3002\u5b89\u88c5\u7ee7\u7eed\uff1b\u7a0d\u540e\u53ef\u7528 --with-backup-client \u5b89\u88c5\u3002'
        'bkc_nokey' = 'ToutWAF Backup \u5ba2\u6237\u7aef\u672a\u5b89\u88c5\uff1a\u7f3a\u5c11\u53d1\u5e03\u516c\u94a5\u3002\u8bf7\u7528 --backup-client-pubkey\uff08\u6216 TOUTWAF_BACKUP_PUBKEY\uff0c\u6216\u914d\u7f6e\u76ee\u5f55\u4e2d\u7684 backup-release.pub\uff09\u63d0\u4f9b\uff1b\u6ca1\u6709\u901a\u8fc7\u6821\u9a8c\u7684\u7b7e\u540d\u5c31\u4e0d\u4f1a\u5b89\u88c5\u4efb\u4f55\u5185\u5bb9\u3002'
        'bkc_badsig' = 'ToutWAF Backup \u5ba2\u6237\u7aef\u672a\u5b89\u88c5\uff1a\u53d1\u5e03\u7b7e\u540d\u65e0\u6548\u3002\u672a\u5b89\u88c5\u4efb\u4f55\u5185\u5bb9\u3002'
        'tele_on' = '\u9065\u6d4b\uff1a\u9ed8\u8ba4\u60c5\u51b5\u4e0b\uff0cToutWAF \u4f1a\u4e0e\u53d1\u5e03\u65b9\u7a7a\u95f4\uff08app.toutwaf.com\uff09\u5171\u4eab\u5176\u62e6\u622a\u7684\u653b\u51fb\uff08\u653b\u51fb\u8005\u5730\u5740\u3001\u56fd\u5bb6\u3001\u653b\u51fb\u7c7b\u578b\u3001\u89c4\u5219\uff09\u3001\u6c47\u603b\u6570\u636e\u4ee5\u53ca\u53d7\u4fdd\u62a4\u7ad9\u70b9\u7684\u4e3b\u673a\u540d\u3002\u7edd\u4e0d\u5305\u542b\u8bf7\u6c42\u5185\u5bb9\uff0c\u4e5f\u7edd\u4e0d\u5305\u542b\u5408\u6cd5\u8bbf\u5ba2\u3002\u53ef\u5728\u63a7\u5236\u53f0\u4e2d\u4e00\u952e\u5173\u95ed\uff08\u8bbe\u7f6e > \u9690\u79c1\u4e0e\u9065\u6d4b\uff09\uff0c\u6216\u4f7f\u7528 --no-telemetry\uff08\u6216 TOUTWAF_TELEMETRY=0\uff09\u5b89\u88c5\u4ee5\u83b7\u5f97\u96f6\u9065\u6d4b\u3002\u8be6\u60c5\uff1adocs/confidentialite-telemetrie.md'
        'tele_off' = '\u9065\u6d4b\uff1a\u5df2\u8bf7\u6c42\u96f6\u9065\u6d4b\uff08--no-telemetry / TOUTWAF_TELEMETRY=0\uff09\u3002\u4e0d\u4f1a\u5411\u53d1\u5e03\u65b9\u7a7a\u95f4\u53d1\u9001\u4efb\u4f55\u5185\u5bb9\uff0c\u4e5f\u4e0d\u4f1a\u4ece\u5b83\u63a5\u6536\u4efb\u4f55\u5185\u5bb9\uff1b\u63a7\u5236\u53f0\u542f\u52a8\u65f6\u201c\u96f6\u9065\u6d4b\u201d\u5f00\u5173\u4e3a\u5f00\u542f\u72b6\u6001\u3002\u60a8\u4ee5\u540e\u53ef\u5728\u63a7\u5236\u53f0\u4e2d\u66f4\u6539\uff08\u8bbe\u7f6e > \u9690\u79c1\u4e0e\u9065\u6d4b\uff09\u3002'
        'fwmod_n2' = '\u6bcf\u9879\u66f4\u6539\u90fd\u5148\u8bd5\u7528\u5e76\u5012\u8ba1\u65f6\uff0c\u82e5\u4e0d\u4fdd\u7559\u4f1a\u81ea\u52a8\u56de\u9000\uff1b\u9632\u9501\u6b7b\u4fdd\u62a4\u4f1a\u62d2\u7edd\u4efb\u4f55\u53ef\u80fd\u5207\u65ad SSH \u6216\u63a7\u5236\u53f0\u7684\u89c4\u5219\u3002'
        'fwmod_n3' = '\u8fd9\u4e0d\u540c\u4e8e\u4e0a\u4e00\u4e2a\u95ee\u9898\uff08\u5b83\u53ea\u5728\u7cfb\u7edf\u9632\u706b\u5899\u4e2d\u653e\u884c ToutWAF \u9700\u8981\u7684\u7aef\u53e3\uff0c\u5bf9\u5e94 --no-firewall\uff09\u3002'
        's_fwmod' = '\u6b63\u5728\u542f\u7528\u9632\u706b\u5899\u6a21\u5757\uff08\u4e0d\u5e94\u7528\u4efb\u4f55\u89c4\u5219\uff09'
        'fwmod_done' = '\u9632\u706b\u5899\u6a21\u5757\u5df2\u542f\u7528\u3002\u672a\u5e94\u7528\u4efb\u4f55\u89c4\u5219\uff1a\u8bf7\u5728\u63a7\u5236\u53f0\u6253\u5f00\u201c\u9632\u706b\u5899\u201d\u6765\u5ba1\u6838\u5e76\u8bd5\u7528\u89c4\u5219\u3002'
        'fwmod_fail' = '\u65e0\u6cd5\u542f\u7528\u9632\u706b\u5899\u6a21\u5757\uff08{0}\uff09\u3002\u5b89\u88c5\u7ee7\u7eed\uff1b\u7a0d\u540e\u53ef\u5728\u201c\u8bbe\u7f6e > \u6a21\u5757\u201d\u4e2d\u542f\u7528\u3002'
        's_link' = '\u6b63\u5728\u5c06\u6570\u636e\u5e73\u9762\u5173\u8054\u5230\u63a7\u5236\u53f0'
        'dp_link_ok' = '\u6570\u636e\u5e73\u9762\u5df2\u81ea\u52a8\u5173\u8054\u5230\u63a7\u5236\u53f0\uff1a\u65e0\u9700\u624b\u52a8\u914d\u7f6e\u3002'
        'dp_link_same' = '\u6570\u636e\u5e73\u9762\u5df2\u5173\u8054\u5230\u63a7\u5236\u53f0\uff1b\u5176\u914d\u7f6e\u672a\u4f5c\u4fee\u6539\u3002'
        'dp_link_fixed' = '\u6570\u636e\u5e73\u9762\u914d\u7f6e\u5df2\u4fee\u590d\uff08\u91cd\u590d\u7684 control_plane \u5757\u5df2\u5408\u5e76\u4e3a\u4e00\u4e2a\uff09\uff1b\u539f\u6587\u4ef6\u5df2\u4fdd\u7559\u3002'
        'dp_link_remote' = '\u6b64\u673a\u5668\u4e0a\u7684\u6570\u636e\u5e73\u9762\u5df2\u914d\u7f6e\u4e3a\u4f7f\u7528\u53e6\u4e00\u4e2a\u63a7\u5236\u53f0\uff1b\u672a\u4f5c\u4fee\u6539\u3002'
        'dp_link_fail' = '\u65e0\u6cd5\u81ea\u52a8\u5c06\u6570\u636e\u5e73\u9762\u5173\u8054\u5230\u63a7\u5236\u53f0\uff1a{0}'
        'dp_link_fail_hint' = '\u6570\u636e\u5e73\u9762\u4fdd\u7559\u5176\u72ec\u7acb\u914d\u7f6e\uff0c\u5728\u5173\u8054\u4e4b\u524d\u7ad9\u70b9\u5c06\u8fd4\u56de HTTP 421\u3002\u8bf7\u6392\u9664\u4e0a\u8ff0\u539f\u56e0\u540e\u91cd\u65b0\u8fd0\u884c\u6b64\u5b89\u88c5\u7a0b\u5e8f\uff1a\u5b83\u4f1a\u81ea\u52a8\u5173\u8054\u8be5\u8282\u70b9\u3002'
        'st_title' = '\u72b6\u6001'
        'st_healthy' = '\u6b63\u5e38'
        'st_unhealthy' = '\u5f02\u5e38'
        'st_active' = '\u8fd0\u884c\u4e2d'
        'st_inactive' = '\u672a\u8fd0\u884c'
        'st_listening' = '\u76d1\u542c\u4e2d'
        'st_closed' = '\u672a\u76d1\u542c'
        'un_title' = '\u6b63\u5728\u5378\u8f7d ToutWAF'
        'un_kept' = '\u914d\u7f6e\u4fdd\u7559\u5728 {0}\uff0c\u6570\u636e\u4fdd\u7559\u5728 {1}\uff08\u4f7f\u7528 --purge \u5220\u9664\uff09\u3002'
        'un_purged' = '\u914d\u7f6e\u3001\u6570\u636e\u548c\u65e5\u5fd7\u5df2\u5220\u9664\u3002'
        'p_console' = 'Web \u63a7\u5236\u53f0 + API'
        'p_http' = 'HTTP\uff08\u53cd\u5411\u4ee3\u7406\uff09'
        'p_https' = 'HTTPS\uff08\u53cd\u5411\u4ee3\u7406\uff09'
        'p_dpapi' = '\u6570\u636e\u5e73\u9762 API\uff1a\u4ec5\u5f53\u6570\u636e\u5e73\u9762\u8fd0\u884c\u5728\u5176\u4ed6\u4e3b\u673a\u65f6\u624d\u9700\u8981\uff08\u9650\u5236\u4e3a\u5176 IP\uff09'
        'w_fw_manual' = '\u7aef\u53e3 {0}/tcp \u672a\u81ea\u52a8\u653e\u884c\uff1a\u8bf7\u89c1\u6458\u8981\u4e2d\u7684\u547d\u4ee4\u3002'
        'need_cp' = '\u63d0\u4f9b\u6ce8\u518c\u4ee4\u724c\u65f6\u9700\u8981\u63a7\u5236\u5e73\u9762 URL\u3002'
        'cp_title' = '\u7cfb\u7edf\u517c\u5bb9\u6027'
        'cp_detected' = '\u68c0\u6d4b\u5230\uff1a{0}\uff0c\u67b6\u6784 {1}\uff0cglibc {2}\uff0csystemd {3}\uff0c\u5185\u6838 {4}'
        'cp_ok' = '\u517c\u5bb9\uff1a{0}\uff08{1}\uff09'
        'cp_tested' = '\u5df2\u6d4b\u8bd5'
        'cp_expected' = '\u9884\u671f\u517c\u5bb9'
        'cp_w_like' = '{0} \u4e0d\u5728\u517c\u5bb9\u6027\u8868\u4e2d\uff1a\u6309 {1} \u7cfb\u5217\u5904\u7406\uff08\u9884\u671f\u517c\u5bb9\uff09\u3002\u7ee7\u7eed\u3002'
        'cp_w_newer' = '{0} {1} \u6bd4\u5217\u51fa\u7684\u7248\u672c\u66f4\u65b0\uff1a\u5c1a\u672a\u9a8c\u8bc1\uff08\u9884\u671f\u517c\u5bb9\uff09\u3002\u7ee7\u7eed\u3002'
        'cp_w_unlisted' = '{0} {1} \u4e0d\u5728\u8868\u4e2d\uff1a\u6309\u9884\u671f\u517c\u5bb9\u5904\u7406\u3002\u7ee7\u7eed\u3002'
        'cp_w_nover' = '{0} \u672a\u62a5\u544a\u7248\u672c\uff08\u6eda\u52a8\u6216\u6d4b\u8bd5\u7248\uff09\uff1a\u6309\u9884\u671f\u517c\u5bb9\u5904\u7406\u3002\u7ee7\u7eed\u3002'
        'cp_w_glibc' = '\u65e0\u6cd5\u786e\u5b9a glibc \u7248\u672c\uff1b\u7ee7\u7eed\u3002'
        'cp_w_skip' = '--skip-os-check\uff1a\u5df2\u8df3\u8fc7\u517c\u5bb9\u6027\u68c0\u67e5\u3002\u6b64\u7cfb\u7edf\u4e0d\u53d7\u652f\u6301\uff1a\u98ce\u9669\u81ea\u8d1f\uff0c\u7ee7\u7eed\u3002'
        'cp_w_stage' = '\u6682\u5b58\u6a21\u5f0f\uff08--destdir\uff09\uff1a\u517c\u5bb9\u6027\u7ed3\u8bba\u4ec5\u4f9b\u53c2\u8003\uff0c\u4e0d\u4f1a\u62d2\u7edd\u3002'
        'cp_refused' = '\u6b64\u7cfb\u7edf\u4e0e ToutWAF \u4e0d\u517c\u5bb9\uff1a'
        'cp_r_old' = '{0} {1} \u4f4e\u4e8e\u652f\u6301\u7684\u6700\u4f4e\u7248\u672c\uff08{2}\uff09\u3002'
        'cp_r_eol' = '{0} {1} \u5df2\u505c\u6b62\u7ef4\u62a4\uff0c\u6216\u5176 glibc / systemd \u8fc7\u65e7\u3002'
        'cp_r_glibc' = '\u53d1\u73b0 glibc {0}\uff1a\u9700\u8981 {1} \u6216\u66f4\u65b0\u7248\u672c\u3002'
        'cp_r_musl' = '\u53d1\u73b0 musl libc\uff1a\u9700\u8981 glibc {0} \u6216\u66f4\u65b0\u7248\u672c\u3002'
        'cp_r_init' = '{0} {1} \u4e0d\u4f7f\u7528 systemd\uff0c\u800c ToutWAF \u9700\u8981\u5b83\u3002'
        'cp_r_immutable' = '{0} {1} \u4f7f\u7528\u4e0d\u53ef\u53d8\u6839\u6587\u4ef6\u7cfb\u7edf\uff08\u4e0d\u652f\u6301\uff09\u3002'
        'cp_r_layout' = '{0} {1} \u4e0d\u9075\u5faa\u6807\u51c6 Linux \u76ee\u5f55\u7ed3\u6784\uff08\u4e0d\u652f\u6301\uff09\u3002'
        'cp_r_arch' = '\u4e0d\u652f\u6301\u67b6\u6784 {0}\uff08\u652f\u6301\uff1a{1}\uff09\u3002'
        'cp_r_distro_arch' = '{0} {1} \u8fd0\u884c\u5728\u6ca1\u6709 ToutWAF \u6784\u5efa\u7684\u67b6\u6784\u4e0a\u3002'
        'cp_r_systemd' = 'systemd \u672a\u4f5c\u4e3a init \u7cfb\u7edf\u8fd0\u884c\uff08\u7f3a\u5c11 /run/systemd/system\uff09\uff1a\u670d\u52a1\u9700\u8981\u5b83\u3002'
        'cp_r_systemd_old' = '\u53d1\u73b0 systemd {0}\uff1a\u9700\u8981 {1} \u6216\u66f4\u65b0\u7248\u672c\u3002'
        'cp_r_kernel' = '\u53d1\u73b0 Linux \u5185\u6838 {0}\uff1a\u9700\u8981 {1} \u6216\u66f4\u65b0\u7248\u672c\u3002'
        'cp_r_unknown' = '\u65e0\u6cd5\u8bc6\u522b\u53d1\u884c\u7248 ''{0}''\uff0c\u4e14\u672a\u58f0\u660e\u5df2\u77e5\u7cfb\u5217\uff08ID_LIKE=''{1}''\uff09\u3002'
        'cp_r_noosr' = '\u7f3a\u5c11 /etc/os-release\uff1a\u65e0\u6cd5\u8bc6\u522b\u53d1\u884c\u7248\u3002'
        'cp_nochange' = '\u672a\u5bf9\u6b64\u7cfb\u7edf\u505a\u4efb\u4f55\u66f4\u6539\u3002'
        'cp_list' = '\u517c\u5bb9\u7684\u7cfb\u7edf\uff08amd64 \u548c arm64\uff0cglibc {0} \u6216\u66f4\u65b0\uff0csystemd {1} \u6216\u66f4\u65b0\uff09\uff1a'
        'cp_rolling' = '\u6eda\u52a8\u53d1\u884c'
        'cp_any' = '\u4efb\u610f\u7248\u672c'
        'cp_override' = '\u4ecd\u8981\u5b89\u88c5\uff08\u98ce\u9669\u81ea\u8d1f\uff09\uff1a--skip-os-check\u3002\u8be6\u60c5\uff1adocs/install/platforms.md'
        'cp_not_root' = '\u672a\u4ee5 root \u8fd0\u884c\uff1a\u5b89\u88c5\u8bf7\u4f7f\u7528 sudo\uff08\u68c0\u67e5\u672c\u8eab\u4e0d\u9700\u8981 root\uff09\u3002'
        'sum_compat' = '\u517c\u5bb9\u6027'
        'cp_prereq_arch' = '\u8f6f\u4ef6\u5305\u6570\u636e\u5e93\u672a\u540c\u6b65\u3002\u8bf7\u5148\u8fd0\u884c ''pacman -Syu''\uff08Arch \u4e0d\u652f\u6301\u90e8\u5206\u5347\u7ea7\uff09\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'cp_wdetected' = '\u68c0\u6d4b\u5230\uff1a{0}\uff08\u5185\u90e8\u7248\u672c {1}\uff09\uff0c\u67b6\u6784 {2}'
        'cp_wlist' = '\u517c\u5bb9\u7684 Windows \u7248\u672c\uff08amd64 \u548c arm64\uff1barm64 \u672a\u5728\u771f\u5b9e\u786c\u4ef6\u4e0a\u6d4b\u8bd5\uff09\uff1a'
        'cp_r_arm32' = 'ToutWAF \u4e0d\u652f\u6301 32 \u4f4d ARM\uff08armv7\uff09\u3002\u8bf7\u5b89\u88c5 64 \u4f4d\u7cfb\u7edf\uff0864 \u4f4d Raspberry Pi OS\u3001Ubuntu \u6216 Debian arm64\uff1bRaspberry Pi 3\u30014\u30015 \u6216 Zero 2 W\uff09\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'cp_r_arm_userland32' = '\u5185\u6838\u662f 64 \u4f4d\uff0c\u4f46\u7cfb\u7edf\uff08\u7528\u6237\u7a7a\u95f4\uff09\u662f 32 \u4f4d\u3002ToutWAF \u9700\u8981 64 \u4f4d\u7cfb\u7edf\uff1a\u8bf7\u91cd\u65b0\u5b89\u88c5 64 \u4f4d Raspberry Pi OS\uff08Raspberry Pi Imager\uff1aRaspberry Pi OS (64-bit)\uff09\u6216 Ubuntu / Debian arm64\u3002'
        'cp_w_pi' = '\u68c0\u6d4b\u5230 Raspberry Pi\uff1aarm64 \u4ec5\u5728\u4eff\u771f\u4e0b\u505a\u8fc7\u5192\u70df\u6d4b\u8bd5\uff0c\u672a\u5728\u771f\u5b9e\u786c\u4ef6\u4e0a\u6d4b\u8bd5\u3002\u8bf7\u628a\u6570\u636e\u548c\u65e5\u5fd7\u653e\u5728 SSD / USB \u76d8\u800c\u4e0d\u662f SD \u5361\u4e0a\uff0c\u5185\u5b58\u4f4e\u4e8e 2 GB \u65f6\u907f\u514d\u4e00\u4f53\u5316\u5b89\u88c5\uff08\u89c1 docs/install/raspberry-pi.md\uff09\u3002'
        'pf_title' = '\u6b63\u5728\u68c0\u67e5\u8fd9\u53f0\u673a\u5668\u7684\u9700\u6c42'
        'pf_ok' = '\u6ca1\u6709\u4efb\u4f55\u963b\u788d\uff1aToutWAF \u9700\u8981\u7684\u7aef\u53e3\u90fd\u662f\u7a7a\u95f2\u7684\u3002'
        'pf_refused' = 'ToutWAF \u65e0\u6cd5\u5728\u8fd9\u53f0\u673a\u5668\u7684\u5f53\u524d\u72b6\u6001\u4e0b\u5b89\u88c5\u3002\u672a\u505a\u4efb\u4f55\u66f4\u6539\u3002'
        'pf_ok_warn' = '\u6ca1\u6709\u4ec0\u4e48\u4f1a\u963b\u6b62\u5b89\u88c5\uff0c\u4f46\u8bf7\u9605\u8bfb\u4e0a\u9762\u7684\u51e0\u70b9\u3002'
        'pf_l_refuse' = '\u62d2\u7edd'
        'pf_l_warn' = '\u6ce8\u610f'
        'pf_l_info' = '\u8bf4\u660e'
        'pf_port_busy' = '{0} \u7aef\u53e3\u5df2\u88ab {1} \u5360\u7528\u3002'
        'pf_prog_other' = '\u53e6\u4e00\u4e2a\u7a0b\u5e8f'
        'pf_prog_unknown' = '\u53e6\u4e00\u4e2a\u7a0b\u5e8f\uff08\u65e0\u6cd5\u8bfb\u53d6\u5176\u540d\u79f0\uff09'
        'pf_act_web' = 'ToutWAF \u9700\u8981 {0} \u548c {1} \u7aef\u53e3\u6765\u4fdd\u62a4\u60a8\u7684\u7ad9\u70b9\u3002\u8bf7\u505c\u6b62\u8be5\u7a0b\u5e8f\uff0c\u6216\u5c06\u5176\u79fb\u5230\u5176\u4ed6\u7aef\u53e3\uff08\u4e0e ToutWAF \u5b89\u88c5\u5728\u4e00\u8d77\u7684 ToutPanel \u4f1a\u628a\u5b83\u7684 Web \u670d\u52a1\u5668\u653e\u5728 8080 \u548c 8443 \u7aef\u53e3\uff09\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'pf_act_console' = 'ToutWAF \u7684\u63a7\u5236\u53f0\u9700\u8981\u4f7f\u7528\u6b64\u7aef\u53e3\u3002\u8bf7\u91ca\u653e\u8be5\u7aef\u53e3\uff0c\u6216\u4e3a\u63a7\u5236\u53f0\u9009\u62e9\u5176\u4ed6\u7aef\u53e3\uff08\u5b89\u88c5\u7a0b\u5e8f\u4f1a\u5728\u83dc\u5355\u4e2d\u8be2\u95ee\uff09\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'pf_act_agent' = 'ToutWAF \u4f7f\u7528\u6b64\u7aef\u53e3\u63a5\u6536\u8fde\u63a5\u5b83\u7684\u6570\u636e\u5e73\u9762\u548c\u4ee3\u7406\u3002\u8bf7\u91ca\u653e\u8be5\u7aef\u53e3\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'pf_act_admin' = '\u6570\u636e\u5e73\u9762\u4ec5\u5728\u8fd9\u53f0\u673a\u5668\u4e0a\u4f7f\u7528\u6b64\u7aef\u53e3\uff0c\u7528\u4e8e\u81ea\u8eab\u7684\u5065\u5eb7\u68c0\u67e5\u3002\u8bf7\u91ca\u653e\u8be5\u7aef\u53e3\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'pf_nostart' = '\uff08\u73b0\u5728\u4e0d\u4f1a\u542f\u52a8\u4efb\u4f55\u670d\u52a1\uff0c\u56e0\u6b64\u4ec5\u4f5c\u63d0\u793a\uff09'
        'pf_boot' = '{0} \u5df2\u5b89\u88c5\u5e76\u4f1a\u968f\u673a\u5668\u542f\u52a8\uff0c\u5c3d\u7ba1\u5b83\u73b0\u5728\u5df2\u505c\u6b62\u3002\u4e0b\u6b21\u91cd\u542f\u540e\uff0c\u5b83\u4f1a\u62a2\u5728 ToutWAF \u4e4b\u524d\u5360\u7528 {1} \u548c {2} \u7aef\u53e3\u3002'
        'pf_act_boot' = '\u8bf7\u5728\u673a\u5668\u91cd\u542f\u524d\u7981\u7528\u5b83\u7684\u5f00\u673a\u542f\u52a8\uff0c\u6216\u5c06\u5176\u79fb\u5230\u5176\u4ed6\u7aef\u53e3\u3002'
        'pf_fw_cause' = '\u9632\u706b\u5899\uff08{0}\uff09\u5904\u4e8e\u542f\u7528\u72b6\u6001\u4e14\u4e0d\u653e\u884c {1} \u548c {2} \u7aef\u53e3\uff0c\u800c\u5b89\u88c5\u7a0b\u5e8f\u88ab\u8981\u6c42\u4e0d\u8981\u4fee\u6539\u5b83\u3002'
        'pf_fw_action' = '\u8bf7\u5728\u9632\u706b\u5899\u4e2d\u5f00\u653e\u8fd9\u4e9b\u7aef\u53e3\uff0c\u6216\u8ba9\u5b89\u88c5\u7a0b\u5e8f\u6765\u505a\uff08\u4e0d\u8981\u4f7f\u7528 --no-firewall \u9009\u9879\uff09\u3002\u5426\u5219\u5916\u90e8\u65e0\u6cd5\u8bbf\u95ee\u60a8\u7684\u7ad9\u70b9\u3002'
        'pf_fwx_cause' = '\u8fd9\u53f0\u673a\u5668\u7684\u9632\u706b\u5899\uff08{0}\uff09\u9ed8\u8ba4\u62d2\u7edd\u5165\u7ad9\u8fde\u63a5\uff0c\u4e14\u6ca1\u6709\u9488\u5bf9 {1} \u548c {2} \u7aef\u53e3\u7684\u89c4\u5219\u3002'
        'pf_fwx_action' = 'ToutWAF \u7edd\u4e0d\u4f1a\u81ea\u884c\u4fee\u6539\u8fd9\u7c7b\u9632\u706b\u5899\u7684\u89c4\u5219\uff1a\u8bf7\u5728\u5176\u914d\u7f6e\u4e2d\u5f00\u653e\u8fd9\u4e9b\u7aef\u53e3\uff0c\u7136\u540e\u68c0\u67e5\u60a8\u7684\u7ad9\u70b9\u3002'
        'pf_cp_cause' = '\u65e0\u6cd5\u4ece\u8fd9\u53f0\u673a\u5668\u8bbf\u95ee\u63a7\u5236\u5e73\u9762 {0}\u3002'
        'pf_cp_action' = '\u8bf7\u68c0\u67e5\u5730\u5740\u3001\u63a7\u5236\u5e73\u9762\u662f\u5426\u5728\u8fd0\u884c\uff0c\u4ee5\u53ca\u5176\u9632\u706b\u5899\u662f\u5426\u5141\u8bb8\u8fd9\u53f0\u673a\u5668\u8bbf\u95ee\u5b83\uff08\u9ed8\u8ba4 9444 \u7aef\u53e3\uff09\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'pf_router_cause' = '\u8fd9\u53f0\u673a\u5668\u4f7f\u7528\u4e13\u7528\u5730\u5740\uff08{0}\uff09\uff1a\u5b83\u5f88\u53ef\u80fd\u4f4d\u4e8e\u8def\u7531\u5668\u4e4b\u540e\u3002'
        'pf_router_action' = '\u5b89\u88c5\u540e\uff0cToutWAF \u4f1a\u663e\u793a\u9700\u8981\u8f6c\u53d1\u5230\u8fd9\u53f0\u673a\u5668\u7684\u7aef\u53e3\uff0c\u5e76\u63d0\u4f9b\u5e38\u89c1\u8def\u7531\u5668\u7684\u914d\u7f6e\u6587\u4ef6\u3002\u73b0\u5728\u65e0\u9700\u51c6\u5907\u4efb\u4f55\u4e1c\u897f\u3002'
        'pf_skipped' = '\u5df2\u6309\u60a8\u7684\u8981\u6c42\u8df3\u8fc7\u73af\u5883\u68c0\u67e5\uff1a\u5b58\u5728\u7684\u963b\u788d\u5c06\u5bfc\u81f4\u4e4b\u540e\u7684\u5b89\u88c5\u6216\u542f\u52a8\u5931\u8d25\u3002'
        's_sysupdate' = '\u6b63\u5728\u66f4\u65b0\u7cfb\u7edf\u8f6f\u4ef6\u5305\uff08\u53ef\u80fd\u9700\u8981\u51e0\u5206\u949f\uff09'
        'su_skipped' = '\u4e0d\u4f1a\u5148\u66f4\u65b0\u7cfb\u7edf\u8f6f\u4ef6\u5305\uff08TOUTWAF_SKIP_SYSUPDATE\uff09\u3002'
        'su_recent' = '\u7cfb\u7edf\u8f6f\u4ef6\u5305\u5728 6 \u5c0f\u65f6\u5185\u5df2\u66f4\u65b0\u8fc7\uff0c\u4e0d\u518d\u91cd\u590d\u3002'
        'su_dry' = '\u5c06\u5148\u66f4\u65b0\u7cfb\u7edf\u8f6f\u4ef6\u5305\uff08\u4f7f\u7528 TOUTWAF_SKIP_SYSUPDATE=1 \u53ef\u8df3\u8fc7\uff09'
        'su_nopm' = '\u6ca1\u6709\u53d7\u652f\u6301\u7684\u5305\u7ba1\u7406\u5668\u53ef\u7528\u4e8e\u66f4\u65b0\u7cfb\u7edf\uff1a\u5df2\u8df3\u8fc7\uff0c\u5b89\u88c5\u7ee7\u7eed\u3002'
        'su_failed' = '\u7cfb\u7edf\u8f6f\u4ef6\u5305\u66f4\u65b0\u5931\u8d25\uff08\u9000\u51fa\u7801 {0}\uff09\uff1b\u5b89\u88c5\u5c06\u5728\u4e0d\u66f4\u65b0\u7684\u60c5\u51b5\u4e0b\u7ee7\u7eed\u3002\u8be6\u60c5\uff1a{1}\u3002\u5904\u7406\u65b9\u6cd5\uff1a\u8bf7\u81ea\u884c\u8fd0\u884c\u66f4\u65b0\u5e76\u67e5\u770b\u9519\u8bef\uff08\u8f6f\u4ef6\u6e90\u635f\u574f\uff1f\u53e6\u4e00\u4e2a\u5305\u7ba1\u7406\u5668\u6b63\u5728\u8fd0\u884c\uff1f\uff09\uff0c\u6216\u52a0\u4e0a TOUTWAF_SKIP_SYSUPDATE=1 \u91cd\u65b0\u8fd0\u884c\u6b64\u547d\u4ee4\u3002'
        'su_reboot' = '\u9700\u8981\u91cd\u542f\u6b64\u670d\u52a1\u5668\u624d\u80fd\u5b8c\u6210\u7cfb\u7edf\u66f4\u65b0\uff08\u65b0\u5185\u6838\u6216\u5e93\uff09\u3002ToutWAF \u7edd\u4e0d\u4f1a\u66ff\u60a8\u91cd\u542f\uff1a\u8bf7\u5728\u65b9\u4fbf\u65f6\u81ea\u884c\u91cd\u542f\u3002'
        'q_sysupdate' = '\u5148\u66f4\u65b0\u7cfb\u7edf\u8f6f\u4ef6\u5305\uff08\u63a8\u8350\uff09\uff1f'
        'pr_disk_full' = '\u4ec5\u5269 {0} MB \u53ef\u7528\u7a7a\u95f4\uff0c\u4f4d\u4e8e {1}\uff08\u81f3\u5c11\u9700\u8981 {2} MB\uff09\uff1a\u5b89\u88c5\u65e0\u6cd5\u5b8c\u6210\u3002'
        'pr_disk_full_a' = '\u8bf7\u91ca\u653e\u4e00\u4e9b\u7a7a\u95f4\uff08\u8f6f\u4ef6\u5305\u7f13\u5b58\uff1aapt-get clean \u6216 dnf clean all\uff1b\u65e7\u65e5\u5fd7\uff1ajournalctl --vacuum-size=100M\uff09\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u6b64\u547d\u4ee4\u3002\u5982\u8981\u5f3a\u884c\u7ee7\u7eed\uff1aTOUTWAF_SKIP_PREREQ=1\u3002'
        'pr_disk_full_w_a' = '\u8bf7\u91ca\u653e\u4e00\u4e9b\u7a7a\u95f4\uff08\u78c1\u76d8\u6e05\u7406\u3001\u6e05\u7a7a\u56de\u6536\u7ad9\uff09\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u6b64\u547d\u4ee4\u3002\u5982\u8981\u5f3a\u884c\u7ee7\u7eed\uff1a$env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = '\u4ec5\u5269 {0} MB \u53ef\u7528\u7a7a\u95f4\uff0c\u4f4d\u4e8e {1}\uff08\u7ea6 {2} MB \u8f83\u4e3a\u5bbd\u88d5\uff09\u3002'
        'pr_disk_low_a' = '\u8bf7\u91ca\u653e\u7a7a\u95f4\u6216\u589e\u52a0\u78c1\u76d8\uff1b\u5b89\u88c5\u53ef\u4ee5\u7ee7\u7eed\u3002'
        'pr_dns' = '\u8fd9\u53f0\u673a\u5668\u65e0\u6cd5\u89e3\u6790\u540d\u79f0 {0}\uff08DNS\uff09\u3002'
        'pr_dns_a' = '\u8bf7\u68c0\u67e5 DNS \u670d\u52a1\u5668\uff08cat /etc/resolv.conf\u3001resolvectl status\uff09\uff0c\u6dfb\u52a0\u4e00\u4e2a\u53ef\u7528\u7684\u670d\u52a1\u5668\uff0c\u4f8b\u5982 nameserver 9.9.9.9\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u6b64\u547d\u4ee4\u3002'
        'pr_dns_w_a' = '\u8bf7\u7528 ''ipconfig /all'' \u68c0\u67e5 DNS \u670d\u52a1\u5668\uff0c\u5728\u7f51\u7edc\u9002\u914d\u5668\u8bbe\u7f6e\u4e2d\u586b\u5165\u4e00\u4e2a\u53ef\u7528\u7684\u670d\u52a1\u5668\uff08\u4f8b\u5982 9.9.9.9\uff09\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u6b64\u547d\u4ee4\u3002'
        'pr_clock' = '\u8fd9\u53f0\u673a\u5668\u7684\u65f6\u949f\u4e0e\u4e92\u8054\u7f51\u65f6\u95f4\u76f8\u5dee {0} \u79d2\uff1a\u65f6\u949f\u4e0d\u51c6\u65f6\uff0cTLS \u8bc1\u4e66\u548c\u7b7e\u540d\u6821\u9a8c\u4f1a\u5931\u8d25\u3002'
        'pr_clock_a' = '\u8bf7\u540c\u6b65\u65f6\u949f\uff1atimedatectl set-ntp true\uff08\u6216 chronyc makestep\uff09\uff0c\u7528 timedatectl \u68c0\u67e5\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u6b64\u547d\u4ee4\u3002'
        'pr_clock_w_a' = '\u8bf7\u540c\u6b65\u65f6\u949f\uff1aw32tm /resync\uff08\u6216 \u8bbe\u7f6e > \u65f6\u95f4\u548c\u8bed\u8a00 > \u7acb\u5373\u540c\u6b65\uff09\uff0c\u7136\u540e\u91cd\u65b0\u8fd0\u884c\u6b64\u547d\u4ee4\u3002'
        'pr_ok' = '\u78c1\u76d8\u7a7a\u95f4\u3001DNS \u548c\u65f6\u949f\u5747\u6b63\u5e38\u3002'
        'cloud_https' = '--cloud-url \u5fc5\u987b\u662f https:// \u5730\u5740\uff08\u8282\u70b9\u7edd\u4e0d\u4ee5\u660e\u6587\u4e0e\u4e91\u7aef\u901a\u4fe1\uff09\u3002'
        'cloud_dp_only' = '--cloud-url \u5b89\u88c5\u9632\u62a4\u8282\u70b9\uff1a\u8bf7\u4e0e --component dp \u4e00\u8d77\u4f7f\u7528\uff08\u4e91\u6a21\u5f0f\u4e0b\u7684\u9ed8\u8ba4\u503c\uff09\u3002'
        'cloud_need_token' = '\u5c06\u6b64\u8282\u70b9\u8fde\u63a5\u5230\u60a8\u7684\u8d26\u6237\u9700\u8981\u6ce8\u518c\u4ee4\u724c\uff08--enroll-token\uff1b\u63a7\u5236\u53f0\uff1a\u8282\u70b9 > \u6dfb\u52a0\u6211\u7684\u7b2c\u4e00\u4e2a\u8282\u70b9\uff09\u3002'
        'cloud_ca_local' = '--cloud-ca \u5fc5\u987b\u662f\u672c\u5730\u6587\u4ef6\u3002'
        'cloud_nolink' = '\u6b64\u7248\u672c\u4e0d\u5305\u542b ToutWAF Cloud \u94fe\u63a5\u7ec4\u4ef6\uff08toutwaf-cloudlink\uff09\uff1a\u8bf7\u66f4\u65b0\u5b89\u88c5\u7a0b\u5e8f\u6216\u4f7f\u7528\u66f4\u65b0\u7684\u7248\u672c\u3002'
        'cloud_enrol_failed' = '\u65e0\u6cd5\u5c06\u8282\u70b9\u6ce8\u518c\u5230\u60a8\u7684\u8d26\u6237\uff08\u89c1\u4e0a\u65b9\u8f93\u51fa\uff09\u3002\u4ee4\u724c\u53ef\u80fd\u5df2\u4f7f\u7528\u6216\u5df2\u8fc7\u671f\uff1a\u8bf7\u5728\u63a7\u5236\u53f0\u4e2d\u521b\u5efa\u65b0\u4ee4\u724c\u3002'
        'pf_cloud_action' = '\u5141\u8bb8\u672c\u673a\u901a\u8fc7 443 \u7aef\u53e3\u8bbf\u95ee\u60a8\u7684 ToutWAF Cloud \u5730\u5740\uff08\u4ec5\u51fa\u7ad9\uff09\uff0c\u5982\u9700\u4ee3\u7406\u8bf7\u8bbe\u7f6e HTTPS_PROXY\u3002\u5165\u7ad9\u65b9\u5411\u65e0\u9700\u5f00\u653e\u4efb\u4f55\u7aef\u53e3\u3002'
        's_db' = '\u6b63\u5728\u51c6\u5907\u6570\u636e\u5e93'
        'db_choose' = 'ToutWAF \u5e94\u4f7f\u7528\u54ea\u79cd\u6570\u636e\u5e93\uff1f'
        'db_opt_pg' = 'PostgreSQL\uff08\u63a8\u8350\uff09'
        'db_opt_pg_local' = '\u5728\u672c\u673a\u5b89\u88c5 PostgreSQL\uff08\u81ea\u52a8\u521b\u5efa\u5e76\u914d\u7f6e\uff09'
        'db_opt_pg_remote' = '\u4f7f\u7528\u73b0\u6709 PostgreSQL \u670d\u52a1\u5668\uff08\u5148\u6d4b\u8bd5\uff0c\u7ecf\u5141\u8bb8\u540e\u81ea\u52a8\u51c6\u5907\uff09'
        'db_opt_sqlite' = 'SQLite\uff08\u5c0f\u578b\u5b89\u88c5\uff0c\u4ec5\u5355\u53f0\u670d\u52a1\u5668\uff09'
        'db_sqlite_note' = 'SQLite \u662f\u672c\u673a\u4e0a\u7684\u4e00\u4e2a\u6587\u4ef6\uff1a\u9002\u5408\u5355\u53f0\u670d\u52a1\u5668\u7684\u5c0f\u578b\u5b89\u88c5\u3002\u5b83\u4e0d\u80fd\u88ab\u591a\u4e2a\u63a7\u5236\u5e73\u9762\u5171\u4eab\uff0c\u4e5f\u6ca1\u6709\u590d\u5236\u529f\u80fd\u3002\u4ee5\u540e\u53ef\u7528 toutwaf-cp db migrate \u8fc1\u79fb\u5230 PostgreSQL\u3002'
        'db_q_host' = 'PostgreSQL \u4e3b\u673a'
        'db_q_port' = '\u7aef\u53e3'
        'db_q_name' = '\u6570\u636e\u5e93\u540d\u79f0'
        'db_q_user' = '\u6570\u636e\u5e93\u7528\u6237'
        'db_q_pw' = '\u8be5\u7528\u6237\u7684\u5bc6\u7801\uff08\u82e5\u7531\u7ba1\u7406\u5458\u8d26\u6237\u521b\u5efa\u5219\u7559\u7a7a\uff09'
        'db_q_tls' = 'TLS \u6a21\u5f0f\uff08disable\u3001prefer\u3001require\u3001verify-ca\u3001verify-full\uff09'
        'db_q_ca' = '\u670d\u52a1\u5668 CA \u8bc1\u4e66\u6587\u4ef6\uff08\u7528\u4e8e verify-ca / verify-full\uff09'
        'db_q_admin' = '\u7528\u4e8e\u521b\u5efa\u7528\u6237\u548c\u6570\u636e\u5e93\u7684\u7ba1\u7406\u5458\u8d26\u6237\uff08\u7559\u7a7a = \u5df2\u5b58\u5728\uff09'
        'db_q_adminpw' = '\u7ba1\u7406\u5458\u8d26\u6237\u5bc6\u7801\uff08\u4ec5\u4f7f\u7528\u4e00\u6b21\uff0c\u4e0d\u4f1a\u4fdd\u5b58\uff09'
        'db_hint' = '\u6570\u636e\u5e93\uff1aSQLite\uff08\u9ed8\u8ba4\uff09\u3002\u670d\u52a1\u5668\u5b89\u88c5\u6216\u591a\u4e2a\u63a7\u5236\u5e73\u9762\u8bf7\u4f7f\u7528 --db postgres\uff08--db-install-local \u4f1a\u81ea\u52a8\u5b89\u88c5\uff09\u3002'
        'db_no_pkg' = '\u65e0\u6cd5\u5728\u6b64\u7cfb\u7edf\u4e0a\u81ea\u52a8\u5b89\u88c5 PostgreSQL\uff1a\u8bf7\u81ea\u884c\u5b89\u88c5\u670d\u52a1\u5668\u8f6f\u4ef6\u5305\uff0c\u7136\u540e\u4f7f\u7528 --db postgres \u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'db_install_failed' = '\u5b89\u88c5 PostgreSQL \u8f6f\u4ef6\u5305\u5931\u8d25\u3002\u539f\u56e0\u89c1\u65e5\u5fd7\uff08/var/log/toutwaf-install.log\uff09\u3002'
        'db_init_failed' = '\u65e0\u6cd5\u521d\u59cb\u5316 PostgreSQL \u96c6\u7fa4\u3002\u539f\u56e0\u89c1\u65e5\u5fd7\u3002'
        'db_start_failed' = 'PostgreSQL \u65e0\u6cd5\u542f\u52a8\u3002\u8bf7\u68c0\u67e5\uff1asystemctl status postgresql \u548c\u65e5\u5fd7\u3002'
        'db_too_old' = '\u6b64\u5904\u5b89\u88c5\u7684 PostgreSQL \u7248\u672c\uff08{0}\uff09\u8fc7\u65e7\uff1a\u9700\u8981 13 \u6216\u66f4\u9ad8\u7248\u672c\u3002'
        'db_exists' = '\u5df2\u5b58\u5728\u7528\u6237\u201c{0}\u201d\u6216\u6570\u636e\u5e93\u201c{1}\u201d\uff0c\u4e14\u4e0d\u662f\u7531\u672c\u5b89\u88c5\u7a0b\u5e8f\u521b\u5efa\u7684\uff1a\u672a\u505a\u4efb\u4f55\u66f4\u6539\u3002\u8bf7\u9009\u62e9\u5176\u4ed6\u540d\u79f0\uff08--db-name\u3001--db-user\uff09\u6216\u63d0\u4f9b\u73b0\u6709\u8fde\u63a5\uff08--db-dsn-file\uff09\u3002'
        'db_create_failed' = '\u65e0\u6cd5\u521b\u5efa\u7528\u6237\u6216\u6570\u636e\u5e93\u3002\u5df2\u521b\u5efa\u7684\u5185\u5bb9\u5df2\u88ab\u5220\u9664\u3002'
        'db_rights' = '\u8be5\u8d26\u6237\u65e0\u6743\u6267\u884c\u6b64\u64cd\u4f5c\u3002\u4e0a\u9762\u7684\u8bed\u53e5\u662f\u670d\u52a1\u5668\u7ba1\u7406\u5458\u81f3\u5c11\u9700\u8981\u6267\u884c\u7684\u5185\u5bb9\uff1b\u6267\u884c\u540e\u8bf7\u91cd\u65b0\u8fd0\u884c\u5b89\u88c5\u7a0b\u5e8f\u3002'
        'db_need_conn' = '\u672a\u63d0\u4f9b\u5230 PostgreSQL \u670d\u52a1\u5668\u7684\u8fde\u63a5\uff1a\u8bf7\u4f7f\u7528 --db-dsn-file\uff0c\u6216 --db-host \u52a0 --db-password-file\uff0c\u6216 --db-install-local\u3002'
        'db_schema_failed' = '\u65e0\u6cd5\u5728\u6570\u636e\u5e93\u4e2d\u521b\u5efa\u8868\u3002\u539f\u56e0\u89c1\u65e5\u5fd7\u3002'
        'db_no_pgdump' = '\u7f3a\u5c11 pg_dump\uff1a\u5728\u5b89\u88c5 PostgreSQL \u5ba2\u6237\u7aef\u8f6f\u4ef6\u5305\u4e4b\u524d\uff0c\u6bcf\u65e5\u6570\u636e\u5e93\u5907\u4efd\u4f1a\u62a5\u9519\u3002'
        'db_sum_engine' = '\u6570\u636e\u5e93\uff1a{0}'
        'db_sum_local' = 'PostgreSQL \u8fd0\u884c\u5728\u672c\u673a\uff08\u4ec5\u56de\u73af\u5730\u5740\uff09\uff1b\u6570\u636e\u5e93 {0}\uff0c\u7528\u6237 {1}\uff08\u65e0\u7ba1\u7406\u5458\u6743\u9650\uff09'
        'db_sum_remote' = '\u73b0\u6709 PostgreSQL \u670d\u52a1\u5668\uff1b\u6570\u636e\u5e93 {0}\uff0c\u7528\u6237 {1}'
        'db_sum_schema' = '\u67b6\u6784\uff1a{0}'
        'db_sum_secret' = '\u8fde\u63a5\u4fe1\u606f\uff08\u542b\u5bc6\u7801\uff09\u4fdd\u5b58\u5728 {0}\uff0c\u4ec5 ToutWAF \u670d\u52a1\u53ef\u8bfb'
        'db_sum_backup' = '\u6bcf\u665a\u8fd0\u884c\u7ecf\u9a8c\u8bc1\u7684 pg_dump\uff08\u4fdd\u7559 7 \u4efd\uff09\uff1b\u72b6\u6001\u89c1\u63a7\u5236\u53f0 Sant\u00e9'
        'db_sum_nobackup' = '\u6ca1\u6709\u81ea\u52a8\u6570\u636e\u5e93\u5907\u4efd\uff1a\u8bf7\u5b89\u6392 pg_dump \u6216\u4f7f\u7528\u6570\u636e\u5e93\u63d0\u4f9b\u5546\u7684\u5907\u4efd'
        'db_sum_sqlite' = '\u6570\u636e\u5e93\uff1aSQLite\uff0c\u672c\u673a\u4e0a\u7684\u4e00\u4e2a\u6587\u4ef6\uff08\u5c0f\u578b\u5b89\u88c5\uff09\u3002\u4ee5\u540e\u53ef\u8fc1\u79fb\u5230 PostgreSQL\uff1atoutwaf-cp db migrate'
        's_extras' = '\u9644\u52a0\u5305\uff1aWindows \u4ee3\u7406\u548c\u6740\u6bd2\u7a0b\u5e8f'
        's_extras_ok' = '\u9644\u52a0\u5305\u5df2\u5b89\u88c5\uff1a{0} \u4e2a\u7a0b\u5e8f\uff0c\u4f4d\u4e8e {1}'
        's_extras_sha' = '\u9644\u52a0\u5305\u5df2\u6821\u9a8c\uff1a{0} \u4e2a\u6587\u4ef6\uff0c{1} MiB\uff08SHA-256 \u4e0e\u7b7e\u540d\uff09'
        's_extras_unchecked' = '\u9644\u52a0\u5305\u6309\u539f\u6837\u4f7f\u7528\uff0c\u6ca1\u6709 SHA256SUMS \u53ef\u4f9b\u6821\u9a8c\uff1a{0}'
        'w_extras_dl' = '\u65e0\u6cd5\u4e0b\u8f7d\u9644\u52a0\u5305\uff08{0}\uff09\u3002ToutWAF \u6ca1\u6709\u5b83\u4eec\u4e5f\u80fd\u8fd0\u884c\uff0c\u4f46\u5728\u5b89\u88c5\u4e4b\u524d\uff0c\u6b64\u63a7\u5236\u53f0\u4e0d\u4f1a\u63d0\u4f9b Windows \u548c\u6740\u6bd2\u529f\u80fd\u3002'
        'w_extras_sum' = '\u9644\u52a0\u5305 {0} \u4e0e\u5df2\u7b7e\u540d SHA256SUMS \u4e2d\u7684 SHA-256 \u4e0d\u4e00\u81f4\uff1a\u672a\u5b89\u88c5\u3002'
        'w_extras_bad' = '\u9644\u52a0\u5305\u6587\u4ef6 {0} \u4e0d\u662f\u6709\u6548\u7684\u9644\u52a0\u5305\u5f52\u6863\uff1a\u672a\u5b89\u88c5\u3002'
        'w_extras_ver' = '\u9644\u52a0\u5305\u9002\u7528\u4e8e\u7248\u672c {0}\uff0c\u800c\u6b64\u5b89\u88c5\u4e3a {1}\uff1a\u672a\u5b89\u88c5\u3002'
        'w_extras_inc' = '\u8be5\u7248\u672c\u5217\u51fa\u4e86\u9644\u52a0\u5305\u7684 {0} \u4e2a\u90e8\u5206\uff0c\u4f46\u58f0\u660e\u5171\u6709 {1} \u4e2a\uff1a\u53d1\u5e03\u5df2\u635f\u574f\uff0c\u672a\u5b89\u88c5\u9644\u52a0\u5305\u3002'
        'w_extras_nofile' = '\u9644\u52a0\u5305\u6587\u4ef6 {0} \u4e0d\u5b58\u5728\u3002'
        'w_extras_none' = '\u6b64\u7248\u672c\u4e0d\u542b\u9644\u52a0\u5305\uff1a\u6b64\u63a7\u5236\u53f0\u4e0d\u4f1a\u63d0\u4f9b Windows \u548c\u6740\u6bd2\u529f\u80fd\u3002'
        'w_extras_todo' = '\u9644\u52a0\u5305\u672a\u5b89\u88c5\u3002\u7f51\u7edc\u53ef\u7528\u65f6\u8bf7\u4ee5 root \u8fd0\u884c\uff1a{0}'
        'extras_needs_cp' = '\u9644\u52a0\u5305\u5c5e\u4e8e\u63a7\u5236\u5e73\u9762\uff1a\u672c\u673a\u672a\u5b89\u88c5\u63a7\u5236\u5e73\u9762\u3002'
        'extras_other_release' = '\u5df2\u53d1\u5e03\u7684\u7248\u672c\uff08{0}\uff09\u4e0d\u662f\u5df2\u5b89\u88c5\u7684\u7248\u672c\uff08{1}\uff09\uff1a\u9644\u52a0\u5305\u968f\u5b83\u4e00\u8d77\u63d0\u4f9b\u3002\u8bf7\u8fd0\u884c --update\u3002'
        'st_extras_ok' = '\u9644\u52a0\u5305\uff1a\u5df2\u5b89\u88c5\uff08Windows \u4ee3\u7406\u3001\u6740\u6bd2\u7a0b\u5e8f\uff09'
        'st_extras_none' = '\u7f3a\u5c11\u9644\u52a0\u5305\uff1a\u4e0d\u63d0\u4f9b Windows \u548c\u6740\u6bd2\u529f\u80fd\u3002\u8bf7\u4ee5 root \u8fd0\u884c\uff1a{0}'
    }
    'ar' = @{
        'tagline' = '\u062d\u0645\u0627\u064a\u0629 \u062a\u0637\u0628\u064a\u0642\u0627\u062a \u0627\u0644\u0648\u064a\u0628 \u0648\u0648\u0627\u062c\u0647\u0627\u062a API'
        'menu_title' = '\u0645\u0627\u0630\u0627 \u062a\u0631\u064a\u062f \u0623\u0646 \u062a\u0641\u0639\u0644\u061f'
        'opt_install' = '\u062a\u062b\u0628\u064a\u062a (\u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u062a\u062d\u0643\u0645 + \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a + \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645)'
        'opt_install_d' = '\u0643\u0644 \u0634\u064a\u0621 \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632: \u0644\u0648\u062d\u0629 \u0627\u0644\u0648\u064a\u0628 \u0648\u0645\u062e\u0632\u0646 \u0627\u0644\u0633\u064a\u0627\u0633\u0627\u062a \u0648\u0627\u0644\u0648\u0643\u064a\u0644 \u0627\u0644\u0639\u0643\u0633\u064a / WAF.'
        'opt_cp' = '\u062a\u062b\u0628\u064a\u062a \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u062a\u062d\u0643\u0645 \u0641\u0642\u0637'
        'opt_cp_d' = '\u0644\u0648\u062d\u0629 \u0627\u0644\u0648\u064a\u0628 \u0648\u0648\u0627\u062c\u0647\u0629 API \u0648\u0645\u062e\u0632\u0646 \u0627\u0644\u0633\u064a\u0627\u0633\u0627\u062a. \u062a\u0646\u0636\u0645 \u0645\u0633\u062a\u0648\u064a\u0627\u062a \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a (\u0627\u0644\u0639\u0642\u062f) \u0644\u0627\u062d\u0642\u0627.'
        'opt_dp' = '\u062a\u062b\u0628\u064a\u062a \u0645\u0633\u062a\u0648\u0649 \u0628\u064a\u0627\u0646\u0627\u062a \u0641\u0642\u0637'
        'opt_dp_d' = '\u0639\u0642\u062f\u0629 \u0648\u0643\u064a\u0644 \u0639\u0643\u0633\u064a / WAF \u062a\u0646\u0636\u0645 \u0625\u0644\u0649 \u0645\u0633\u062a\u0648\u0649 \u062a\u062d\u0643\u0645 \u0642\u0627\u0626\u0645 (\u062a\u0637\u0644\u0628 \u0639\u0646\u0648\u0627\u0646\u0647 \u0648\u0631\u0645\u0632 \u0627\u0644\u062a\u0633\u062c\u064a\u0644).'
        'opt_update' = '\u062a\u062d\u062f\u064a\u062b'
        'opt_update_d' = '\u064a\u0646\u0632\u0644 \u0625\u0635\u062f\u0627\u0631\u0627 \u0623\u062d\u062f\u062b \u0648\u064a\u062a\u062d\u0642\u0642 \u0645\u0646\u0647 (SHA-256 / sigstore) \u0648\u064a\u0646\u0634\u0626 \u0646\u0633\u062e\u0629 \u0627\u062d\u062a\u064a\u0627\u0637\u064a\u0629 \u0648\u064a\u062d\u062a\u0641\u0638 \u0628\u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a \u0648\u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0648\u064a\u062a\u0631\u0627\u062c\u0639 \u0639\u0646\u062f \u0627\u0644\u0641\u0634\u0644.'
        'opt_uninstall' = '\u0625\u0632\u0627\u0644\u0629 \u0627\u0644\u062a\u062b\u0628\u064a\u062a'
        'opt_uninstall_d' = '\u064a\u0632\u064a\u0644 ToutWAF\u061b \u062a\u062e\u062a\u0627\u0631 \u0627\u0644\u0627\u062d\u062a\u0641\u0627\u0638 \u0628\u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a \u0648\u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0648\u0627\u0644\u0633\u062c\u0644\u0627\u062a \u0623\u0648 \u062d\u0630\u0641\u0647\u0627.'
        'opt_status' = '\u0627\u0644\u062d\u0627\u0644\u0629 \u0648\u0641\u062d\u0635 \u0627\u0644\u0633\u0644\u0627\u0645\u0629'
        'opt_status_d' = '\u0627\u0644\u0625\u0635\u062f\u0627\u0631\u0627\u062a \u0627\u0644\u0645\u062b\u0628\u062a\u0629 \u0648\u0627\u0644\u062e\u062f\u0645\u0627\u062a \u0648\u0627\u0644\u0645\u0646\u0627\u0641\u0630 \u0627\u0644\u0645\u0641\u062a\u0648\u062d\u0629 \u0648\u0646\u0642\u0627\u0637 \u0641\u062d\u0635 \u0627\u0644\u0633\u0644\u0627\u0645\u0629.'
        'opt_links' = '\u0639\u0631\u0636 \u0631\u0648\u0627\u0628\u0637 \u0627\u0644\u0644\u0648\u062d\u0629 \u0645\u0631\u0629 \u0623\u062e\u0631\u0649'
        'opt_links_d' = '\u0639\u0646\u0627\u0648\u064a\u0646 \u0627\u0644\u0644\u0648\u062d\u0629 \u0648\u0631\u0627\u0628\u0637 \u0627\u0644\u0625\u0639\u062f\u0627\u062f \u0644\u0645\u0631\u0629 \u0648\u0627\u062d\u062f\u0629 \u0648\u0627\u0644\u0645\u0646\u0627\u0641\u0630 \u0627\u0644\u0645\u0637\u0644\u0648\u0628 \u0641\u062a\u062d\u0647\u0627 \u0641\u064a \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629.'
        'opt_quit' = '\u062e\u0631\u0648\u062c'
        'choice' = '\u0627\u062e\u062a\u064a\u0627\u0631\u0643'
        'invalid_choice' = '\u0627\u062e\u062a\u064a\u0627\u0631 \u063a\u064a\u0631 \u0635\u0627\u0644\u062d.'
        'state_installed' = '\u0627\u0644\u0645\u062b\u0628\u062a: {0}'
        'state_none' = 'ToutWAF \u063a\u064a\u0631 \u0645\u062b\u0628\u062a \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632.'
        'cfg_title' = '\u062e\u064a\u0627\u0631\u0627\u062a \u0627\u0644\u062a\u062b\u0628\u064a\u062a (Enter = \u0627\u0644\u0627\u0641\u062a\u0631\u0627\u0636\u064a)'
        'q_cp_url' = '\u0639\u0646\u0648\u0627\u0646 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u062a\u062d\u0643\u0645 (\u0645\u062b\u0627\u0644 https://cp.example.com:9444)'
        'q_token' = '\u0631\u0645\u0632 \u0627\u0644\u062a\u0633\u062c\u064a\u0644 (\u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645: \u0627\u0644\u0639\u0642\u062f > \u0625\u0636\u0627\u0641\u0629 \u0639\u0642\u062f\u0629)'
        'q_cp_ca' = '\u0645\u0644\u0641 PEM \u0644\u0634\u0647\u0627\u062f\u0629 / \u0645\u0631\u062c\u0639 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u062a\u062d\u0643\u0645 (\u0641\u0627\u0631\u063a = \u0645\u062e\u0632\u0646 \u0627\u0644\u0646\u0638\u0627\u0645)'
        'q_cp_port' = '\u0645\u0646\u0641\u0630 \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645'
        'q_http_port' = '\u0645\u0646\u0641\u0630 HTTP'
        'q_https_port' = '\u0645\u0646\u0641\u0630 HTTPS'
        'q_public_host' = '\u0627\u0633\u0645 \u0627\u0644\u0645\u0636\u064a\u0641 \u0623\u0648 \u0639\u0646\u0648\u0627\u0646 IP \u0627\u0644\u0639\u0627\u0645 (\u0641\u0627\u0631\u063a = \u0627\u0643\u062a\u0634\u0627\u0641 \u062a\u0644\u0642\u0627\u0626\u064a)'
        'q_firewall' = '\u0641\u062a\u062d \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629 \u062a\u0644\u0642\u0627\u0626\u064a\u0627 (firewalld / ufw)\u061f'
        'q_boot' = '\u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u062e\u062f\u0645\u0627\u062a \u0639\u0646\u062f \u0627\u0644\u0625\u0642\u0644\u0627\u0639\u061f'
        'q_channel' = '\u0642\u0646\u0627\u0629 \u0627\u0644\u0625\u0635\u062f\u0627\u0631\u0627\u062a (stable / dev)'
        'q_bindir' = '\u0645\u062c\u0644\u062f \u0627\u0644\u062a\u062b\u0628\u064a\u062a'
        'q_confirm' = '\u0627\u0644\u0645\u062a\u0627\u0628\u0639\u0629 \u0641\u064a \u0627\u0644\u062a\u062b\u0628\u064a\u062a\u061f'
        'q_purge' = '\u062d\u0630\u0641 \u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a \u0648\u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0648\u0627\u0644\u0633\u062c\u0644\u0627\u062a \u0623\u064a\u0636\u0627\u061f (\u0644\u0627 = \u0627\u0644\u0627\u062d\u062a\u0641\u0627\u0638 \u0628\u0647\u0627)'
        'q_confirm_un' = '\u0647\u0644 \u062a\u0631\u064a\u062f \u0641\u0639\u0644\u0627 \u0625\u0632\u0627\u0644\u0629 ToutWAF\u061f'
        'aborted' = '\u062a\u0645 \u0627\u0644\u0625\u0644\u063a\u0627\u0621.'
        'root_required' = '\u0634\u063a\u0651\u0644 \u0627\u0644\u0633\u0643\u0631\u0628\u062a \u0628\u0635\u0644\u0627\u062d\u064a\u0627\u062a root (sudo bash install.sh).'
        's_prereq' = '\u062a\u062b\u0628\u064a\u062a \u0627\u0644\u0645\u062a\u0637\u0644\u0628\u0627\u062a'
        's_fetch' = '\u062a\u0646\u0632\u064a\u0644 ToutWAF {0} ({1})'
        's_sha' = '\u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 SHA-256'
        's_sig' = '\u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u062a\u0648\u0642\u064a\u0639 cosign'
        'w_nocosign' = 'cosign \u063a\u064a\u0631 \u0645\u062b\u0628\u062a: \u0644\u0645 \u064a\u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u062a\u0648\u0642\u064a\u0639 (\u0627\u0644\u0645\u062c\u0645\u0648\u0639 \u0627\u0644\u0627\u062e\u062a\u0628\u0627\u0631\u064a \u0641\u0642\u0637)'
        's_user' = '\u0625\u0646\u0634\u0627\u0621 \u062d\u0633\u0627\u0628 \u0627\u0644\u062e\u062f\u0645\u0629 \u0648\u0627\u0644\u0645\u062c\u0644\u062f\u0627\u062a'
        's_bin' = '\u062a\u062b\u0628\u064a\u062a \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0627\u0644\u062a\u0646\u0641\u064a\u0630\u064a\u0629'
        's_cfg' = '\u0643\u062a\u0627\u0628\u0629 \u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a (\u062a\u0628\u0642\u0649 \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0627\u0644\u0645\u0648\u062c\u0648\u062f\u0629)'
        's_units' = '\u062a\u062b\u0628\u064a\u062a \u0648\u062d\u062f\u0627\u062a systemd \u0648\u0636\u0628\u0637 \u0627\u0644\u0646\u0638\u0627\u0645'
        's_selinux' = '\u0625\u0639\u062f\u0627\u062f SELinux'
        'q_console_from' = '\u0627\u0644\u0633\u0645\u0627\u062d \u0644\u0647\u0630\u0647 \u0627\u0644\u0634\u0628\u0643\u0629 \u0641\u0642\u0637 \u0628\u0627\u0644\u0648\u0635\u0648\u0644 \u0625\u0644\u0649 \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 (CIDR \u0645\u062b\u0644 203.0.113.0/24\u061b \u0641\u0627\u0631\u063a = \u0627\u0644\u062c\u0645\u064a\u0639)'
        'q_console_from_bad' = '\u0644\u064a\u0633 \u0639\u0646\u0648\u0627\u0646\u0627 \u0648\u0644\u0627 CIDR \u0635\u0627\u0644\u062d\u0627 (0.0.0.0/0 \u064a\u0639\u0627\u062f\u0644 \u0641\u0627\u0631\u063a\u0627): \u064a\u0628\u0642\u0649 \u0645\u0646\u0641\u0630 \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 \u0645\u0641\u062a\u0648\u062d\u0627 \u0644\u0644\u062c\u0645\u064a\u0639.'
        'fw_console_note' = '\u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 (\u0627\u0644\u0645\u0646\u0641\u0630 {0}) \u062a\u062d\u0648\u064a \u062a\u0633\u062c\u064a\u0644 \u062f\u062e\u0648\u0644 \u0627\u0644\u0625\u062f\u0627\u0631\u0629: \u0641\u062a\u062d\u0647\u0627 \u0644\u0643\u0644 \u0627\u0644\u0625\u0646\u062a\u0631\u0646\u062a \u0645\u0631\u064a\u062d \u0644\u0643\u0646\u0647 \u0645\u0639\u0631\u0651\u0636 \u0644\u0644\u062e\u0637\u0631.'
        'fw_console_open' = '\u0645\u0646\u0641\u0630 \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 {0} \u0645\u0641\u062a\u0648\u062d \u0644\u0644\u062c\u0645\u064a\u0639: \u0642\u064a\u0651\u062f\u0647 \u0628\u0640 --console-from CIDR \u0623\u0648 \u0645\u0646 \u0627\u0644\u0644\u0648\u062d\u0629 (\u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a > \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629)'
        'fw_console_from' = '\u0645\u0646\u0641\u0630 \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 {0} \u0645\u0641\u062a\u0648\u062d \u0641\u0642\u0637 \u0644\u0640 {1}'
        'fw_none' = '\u0644\u0645 \u064a\u064f\u0639\u062b\u0631 \u0639\u0644\u0649 \u062c\u062f\u0627\u0631 \u062d\u0645\u0627\u064a\u0629 \u0646\u0634\u0637 (firewalld / ufw / nftables / iptables): \u0644\u0627 \u0634\u064a\u0621 \u064a\u0631\u0634\u062d \u0627\u0644\u062d\u0631\u0643\u0629 \u0648\u0644\u0627 \u0645\u0646\u0627\u0641\u0630 \u0644\u0641\u062a\u062d\u0647\u0627'
        'fw_manual' = '\u0644\u0627 \u064a\u0639\u062f\u0651\u0644 \u0627\u0644\u0645\u062b\u0628\u0651\u062a \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629 {0}: \u0646\u0641\u0651\u0630 \u0647\u0630\u0647 \u0627\u0644\u0623\u0648\u0627\u0645\u0631 \u0628\u0646\u0641\u0633\u0643'
        'fw_failed' = '\u062a\u0639\u0630\u0631 \u0625\u0639\u062f\u0627\u062f \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629: {0}'
        'home_fresh' = '\u062a\u062b\u0628\u064a\u062a \u062c\u062f\u064a\u062f: \u0643\u0644 \u0634\u064a\u0621 \u062a\u062d\u062a {0} (bin \u0648conf \u0648data \u0648logs)'
        'home_legacy' = '\u062a\u0645 \u0627\u0643\u062a\u0634\u0627\u0641 \u062a\u062b\u0628\u064a\u062a \u0642\u0627\u0626\u0645: \u062a\u0628\u0642\u0649 \u0645\u0633\u0627\u0631\u0627\u062a\u0647 (bin {0} \u0648conf {1} \u0648data {2}). \u0644\u0627 \u064a\u064f\u0646\u0642\u0644 \u0634\u064a\u0621\u061b \u0627\u0633\u062a\u062e\u062f\u0645 --home DIR \u0644\u0644\u062a\u062e\u0637\u064a\u0637 \u0627\u0644\u062c\u062f\u064a\u062f.'
        'home_explicit_legacy' = '\u062a\u0645 \u062a\u062d\u062f\u064a\u062f --home {0} \u0628\u064a\u0646\u0645\u0627 \u064a\u0648\u062c\u062f \u062a\u062b\u0628\u064a\u062a \u0641\u064a {1}: \u0628\u064a\u0627\u0646\u0627\u062a\u0647 \u0644\u0627 \u062a\u064f\u0646\u0642\u0644'
        'home_bad' = '\u064a\u062c\u0628 \u0623\u0646 \u064a\u0643\u0648\u0646 --home \u0645\u0633\u0627\u0631\u0627 \u0645\u0637\u0644\u0642\u0627 (\u062d\u0631\u0648\u0641 \u0648\u0623\u0631\u0642\u0627\u0645 . _ - + /) \u0648\u0644\u064a\u0633 / \u0648\u0644\u0627 \u062a\u062d\u062a /proc /sys /dev: {0}'
        'home_noexec' = '{0} \u0639\u0644\u0649 \u0646\u0642\u0637\u0629 \u062a\u0631\u0643\u064a\u0628 noexec: \u0644\u0627 \u064a\u0645\u0643\u0646 \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0627\u0644\u062a\u0646\u0641\u064a\u0630\u064a\u0629 \u0647\u0646\u0627\u0643\u060c \u0627\u062e\u062a\u0631 --home \u0622\u062e\u0631'
        's_fw' = '\u0625\u0639\u062f\u0627\u062f \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629'
        's_boot' = '\u062a\u062c\u0647\u064a\u0632 \u0627\u0644\u0644\u0648\u062d\u0629 (\u062d\u0633\u0627\u0628 \u0627\u0644\u0645\u0633\u0624\u0648\u0644 \u0648\u0627\u0644\u0645\u0633\u0627\u0631 \u0627\u0644\u0622\u0645\u0646)'
        's_start' = '\u0628\u062f\u0621 \u0627\u0644\u062e\u062f\u0645\u0627\u062a'
        's_health' = '\u0627\u0646\u062a\u0638\u0627\u0631 \u062c\u0627\u0647\u0632\u064a\u0629 \u0627\u0644\u062e\u062f\u0645\u0627\u062a'
        's_backup' = '\u0646\u0633\u062e \u0627\u062d\u062a\u064a\u0627\u0637\u064a \u0644\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a \u0648\u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a'
        'w_rollback' = '\u0627\u0644\u0625\u0635\u062f\u0627\u0631 \u0627\u0644\u062c\u062f\u064a\u062f \u063a\u064a\u0631 \u0633\u0644\u064a\u0645: \u062c\u0627\u0631 \u0627\u0644\u062a\u0631\u0627\u062c\u0639 \u0625\u0644\u0649 \u0627\u0644\u0633\u0627\u0628\u0642'
        'up_to_date' = '\u0645\u062d\u062f\u0651\u062b \u0628\u0627\u0644\u0641\u0639\u0644 ({0})'
        'not_installed' = 'ToutWAF \u063a\u064a\u0631 \u0645\u062b\u0628\u062a: \u0644\u0627 \u0634\u064a\u0621 \u0644\u0644\u062a\u062d\u062f\u064a\u062b.'
        'st_channel' = '\u0627\u0644\u0642\u0646\u0627\u0629: {0}'
        'st_latest' = '\u0623\u062d\u062f\u062b \u0625\u0635\u062f\u0627\u0631 \u0645\u062a\u0627\u062d: {0}'
        'st_newer' = '\u062a\u062d\u062f\u064a\u062b \u0645\u062a\u0627\u062d: \u0634\u063a\u0651\u0644 \u0645\u0639 --update'
        'e_yanked' = '\u062a\u0645 \u0633\u062d\u0628 \u0627\u0644\u0625\u0635\u062f\u0627\u0631 {0} (yanked) \u0648\u0644\u0627 \u064a\u062c\u0628 \u062a\u062b\u0628\u064a\u062a\u0647. \u0634\u063a\u0651\u0644 --update \u0644\u0644\u0625\u0635\u062f\u0627\u0631 \u0627\u0644\u062d\u0627\u0644\u064a \u0623\u0648 --force \u0644\u0644\u062a\u062c\u0627\u0648\u0632.'
        'e_nover' = '\u0644\u0645 \u064a\u064f\u0646\u0634\u0631 \u0623\u064a \u0625\u0635\u062f\u0627\u0631 \u0639\u0644\u0649 \u0627\u0644\u0642\u0646\u0627\u0629 {0} \u0628\u0639\u062f\u060c \u0644\u0630\u0644\u0643 \u0644\u0627 \u064a\u0648\u062c\u062f \u0645\u0627 \u064a\u0645\u0643\u0646 \u062a\u062b\u0628\u064a\u062a\u0647. \u0644\u0645 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a ToutWAF \u0623\u0648 \u062a\u063a\u064a\u064a\u0631\u0647. \u0644\u0644\u062a\u062b\u0628\u064a\u062a \u0645\u0646 \u0627\u0644\u0642\u0646\u0627\u0629 {1} \u0634\u063a\u0651\u0644 \u0627\u0644\u0645\u062b\u0628\u0651\u062a \u0645\u062c\u062f\u062f\u064b\u0627 \u0645\u0639 -Channel {2}.'
        'e_installer_old' = '\u0647\u0630\u0627 \u0627\u0644\u0645\u062b\u0628\u0651\u062a \u0642\u062f\u064a\u0645 \u062c\u062f\u064b\u0627 \u0644\u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631 (\u064a\u062a\u0637\u0644\u0628 \u0627\u0644\u0625\u0635\u062f\u0627\u0631 {0}): \u0646\u0632\u0651\u0644\u0647 \u0645\u0646 \u062c\u062f\u064a\u062f \u0645\u0646 \u0639\u0646\u0648\u0627\u0646 \u0627\u0644\u0642\u0646\u0627\u0629.'
        'up_rebuilt' = '\u0627\u0644\u0625\u0635\u062f\u0627\u0631 \u0646\u0641\u0633\u0647 \u0648\u0628\u0646\u0627\u0621 \u062c\u062f\u064a\u062f: \u0627\u0644\u0645\u062b\u0628\u0651\u062a {0}\u060c \u0627\u0644\u0645\u062a\u0627\u062d {1}. \u062c\u0627\u0631\u064d \u0627\u0644\u062a\u062d\u062f\u064a\u062b.'
        'st_newbuild' = '\u0627\u0644\u0625\u0635\u062f\u0627\u0631 \u0646\u0641\u0633\u0647 \u0648\u0628\u0646\u0627\u0621 \u062c\u062f\u064a\u062f \u0645\u062a\u0627\u062d: \u0634\u063a\u0651\u0644 \u0645\u062c\u062f\u062f\u064b\u0627 \u0645\u0639 {0}'
        'st_nochannel' = '\u0623\u062d\u062f\u062b \u0625\u0635\u062f\u0627\u0631 \u0645\u062a\u0627\u062d: \u0644\u0645 \u064a\u064f\u0646\u0634\u0631 \u0634\u064a\u0621 \u0641\u064a \u0647\u0630\u0647 \u0627\u0644\u0642\u0646\u0627\u0629 \u0628\u0639\u062f'
        'w_mirror' = '\u0642\u062f\u0651\u0645\u062a \u0627\u0644\u0645\u0631\u0622\u0629 \u0627\u0644\u0639\u0627\u0645\u0629 \u0645\u0644\u0641\u0627\u062a \u063a\u064a\u0631 \u0645\u062a\u0633\u0642\u0629 \u0641\u064a\u0645\u0627 \u0628\u064a\u0646\u0647\u0627 ({0}): \u0631\u0628\u0645\u0627 \u0645\u0627 \u0632\u0627\u0644\u062a \u062a\u064f\u062d\u062f\u064e\u0651\u062b \u0628\u0639\u062f \u0627\u0644\u0646\u0634\u0631. \u0633\u062a\u064f\u0639\u0627\u062f \u0642\u0631\u0627\u0621\u0629 \u0627\u0644\u0642\u0646\u0627\u0629 \u0645\u0631\u0629 \u0648\u0627\u062d\u062f\u0629.'
        'e_mismatch' = '\u0645\u062c\u0645\u0648\u0639 \u0627\u0644\u062a\u062d\u0642\u0642 \u063a\u064a\u0631 \u0645\u0637\u0627\u0628\u0642 \u0644\u0640 {0} ({1}): \u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0630\u064a \u0646\u064f\u0632\u0650\u0651\u0644 \u0644\u0627 \u064a\u0637\u0627\u0628\u0642 \u0627\u0644\u0645\u062c\u0645\u0648\u0639 \u0627\u0644\u0645\u0646\u0634\u0648\u0631\u060c \u0644\u0630\u0644\u0643 \u0644\u0645 \u064a\u064f\u062b\u0628\u064e\u0651\u062a \u0623\u0648 \u064a\u064f\u063a\u064a\u064e\u0651\u0631 \u0623\u064a \u0634\u064a\u0621. \u0628\u0639\u062f \u0627\u0644\u0646\u0634\u0631 \u0645\u0628\u0627\u0634\u0631\u0629 \u0642\u062f \u062a\u0642\u062f\u0651\u0645 \u0627\u0644\u0645\u0631\u0622\u0629 \u0627\u0644\u0639\u0627\u0645\u0629 \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0627\u0644\u0633\u0627\u0628\u0642\u0629 \u0644\u0628\u0636\u0639 \u062f\u0642\u0627\u0626\u0642: \u0627\u0646\u062a\u0638\u0631 \u062e\u0645\u0633 \u062f\u0642\u0627\u0626\u0642 \u0648\u0634\u063a\u0651\u0644 \u0627\u0644\u0645\u062b\u0628\u0651\u062a \u0645\u062c\u062f\u062f\u064b\u0627. \u0625\u0646 \u062a\u0643\u0631\u0631 \u0630\u0644\u0643 \u0641\u0644\u0627 \u062a\u062b\u0628\u0651\u062a: \u0627\u0644\u0646\u0634\u0631 \u062a\u0627\u0644\u0641.'
        'e_downgrade' = '\u0623\u062d\u062f\u062b \u0625\u0635\u062f\u0627\u0631 {0} \u0641\u064a \u0627\u0644\u0642\u0646\u0627\u0629 {1} \u0623\u0642\u062f\u0645 \u0645\u0646 \u0627\u0644\u0645\u062b\u0628\u0651\u062a {2}: \u0627\u0633\u062a\u062e\u062f\u0645 --force \u0644\u0644\u0631\u062c\u0648\u0639.'
        's_sigok' = '\u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u062a\u0648\u0642\u064a\u0639 \u0627\u0644\u0625\u0635\u062f\u0627\u0631\u060c \u0627\u0644\u0645\u0641\u062a\u0627\u062d {0}'
        'w_sigold' = '\u0627\u0644\u0625\u0635\u062f\u0627\u0631 {0} \u0646\u064f\u0634\u0631 \u0628\u062f\u0648\u0646 \u062a\u0648\u0642\u064a\u0639 (\u0627\u0644\u0625\u0635\u062f\u0627\u0631\u0627\u062a \u0642\u0628\u0644 0.2.0-dev.7 \u063a\u064a\u0631 \u0645\u0648\u0642\u0651\u0639\u0629): \u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 SHA-256 \u0641\u0642\u0637 \u0648\u0644\u0645 \u064a\u0645\u0643\u0646 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u062a\u0648\u0642\u064a\u0639'
        'w_sigskip' = '\u0644\u0645 \u064a\u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u062a\u0648\u0642\u064a\u0639 \u0627\u0644\u0625\u0635\u062f\u0627\u0631: \u0644\u0645 \u064a\u062a\u0645 \u0627\u0644\u0639\u062b\u0648\u0631 \u0639\u0644\u0649 openssl.exe \u0641\u064a PATH (\u0644\u0627 \u064a\u0648\u0641\u0631 Windows \u062a\u062d\u0642\u0642\u0627 \u0645\u062f\u0645\u062c\u0627 \u0645\u0646 Ed25519) \u0648\u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 SHA-256 \u0641\u0642\u0637. \u062b\u0628\u0651\u062a OpenSSL 3 \u0648\u0623\u0639\u062f \u0627\u0644\u062a\u0634\u063a\u064a\u0644 \u0644\u0644\u062a\u062d\u0642\u0642 \u0628\u0627\u0644\u0645\u0641\u062a\u0627\u062d {0}'
        'done' = '\u062a\u0645.'
        'failed' = '\u0641\u0634\u0644'
        'log_hint' = '\u0627\u0644\u0633\u062c\u0644 \u0627\u0644\u0643\u0627\u0645\u0644: {0}'
        'dry_done' = '\u062a\u0634\u063a\u064a\u0644 \u062a\u062c\u0631\u064a\u0628\u064a: \u0644\u0645 \u064a\u062a\u0645 \u062a\u063a\u064a\u064a\u0631 \u0623\u064a \u0634\u064a\u0621.'
        'sum_title' = '\u0645\u0644\u062e\u0635 \u0627\u0644\u062a\u062b\u0628\u064a\u062a'
        'sum_panel' = '\u0631\u0648\u0627\u0628\u0637 \u0627\u0644\u0644\u0648\u062d\u0629'
        'sum_tls_note' = 'HTTPS \u0641\u0642\u0637. \u0627\u0644\u0634\u0647\u0627\u062f\u0629 \u0645\u0648\u0642\u0639\u0629 \u0630\u0627\u062a\u064a\u0627 \u062d\u062a\u0649 \u062a\u062b\u0628\u062a \u0634\u0647\u0627\u062f\u062a\u0643: \u0633\u064a\u0639\u0631\u0636 \u0627\u0644\u0645\u062a\u0635\u0641\u062d \u062a\u062d\u0630\u064a\u0631\u0627.'
        'sum_local' = '\u0627\u0644\u0639\u0646\u0627\u0648\u064a\u0646 \u0627\u0644\u0645\u062d\u0644\u064a\u0629'
        'sum_public' = '\u0627\u0644\u0639\u0646\u0648\u0627\u0646 \u0627\u0644\u0639\u0627\u0645'
        'sum_public_unknown' = '\u062a\u0639\u0630\u0631 \u0627\u0643\u062a\u0634\u0627\u0641 \u0639\u0646\u0648\u0627\u0646 IP \u0627\u0644\u0639\u0627\u0645 (\u062f\u0648\u0646 \u0627\u062a\u0635\u0627\u0644 \u0623\u0648 \u0645\u062d\u062c\u0648\u0628). \u0627\u0633\u062a\u062e\u062f\u0645 \u0639\u0646\u0648\u0627\u0646 IP \u0627\u0644\u0639\u0627\u0645 \u0644\u062e\u0627\u062f\u0645\u0643 \u0623\u0648 \u0627\u0633\u0645 DNS \u0628\u062f\u0644\u0627 \u0645\u0646 \u0627\u0644\u0639\u0646\u0627\u0648\u064a\u0646 \u0627\u0644\u0645\u062d\u0644\u064a\u0629\u060c \u0623\u0648 \u0623\u0639\u062f \u0627\u0644\u062a\u0634\u063a\u064a\u0644 \u0645\u0639 --public-host.'
        'sum_admin' = '\u062d\u0633\u0627\u0628 \u0627\u0644\u0645\u0633\u0624\u0648\u0644'
        'sum_user' = '\u0627\u0633\u0645 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645'
        'sum_password' = '\u0643\u0644\u0645\u0629 \u0627\u0644\u0645\u0631\u0648\u0631'
        'sum_pw_once' = '\u062a\u0638\u0647\u0631 \u0645\u0631\u0629 \u0648\u0627\u062d\u062f\u0629 \u0641\u0642\u0637 - \u064a\u0645\u0643\u0646 \u062a\u063a\u064a\u064a\u0631\u0647\u0627 \u0641\u064a \u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a > \u0627\u0644\u0648\u0635\u0648\u0644 / \u0627\u0644\u062d\u0633\u0627\u0628'
        'sum_pw_unchanged' = '\u062f\u0648\u0646 \u062a\u063a\u064a\u064a\u0631 (\u0644\u0627 \u064a\u0639\u0627\u062f \u062a\u0648\u0644\u064a\u062f\u0647\u0627 \u0623\u0628\u062f\u0627). \u0644\u0625\u0639\u0627\u062f\u0629 \u0627\u0644\u062a\u0639\u064a\u064a\u0646: toutwaf-cp admin reset-password --user {0}'
        'sum_setup' = '\u0631\u0627\u0628\u0637 \u0627\u0644\u0625\u0639\u062f\u0627\u062f \u0644\u0645\u0631\u0629 \u0648\u0627\u062d\u062f\u0629'
        'sum_setup_note' = '\u0627\u0641\u062a\u062d\u0647 \u0644\u0636\u0628\u0637 \u0631\u0627\u0628\u0637 \u0627\u0644\u0644\u0648\u062d\u0629 \u0648\u0627\u0644\u062d\u0633\u0627\u0628 \u0648\u0643\u0644\u0645\u0629 \u0627\u0644\u0645\u0631\u0648\u0631 \u0641\u064a \u0645\u0639\u0627\u0644\u062c \u0627\u0644\u0648\u064a\u0628.'
        'p_dpapi_warn' = '\u0627\u0644\u0645\u0646\u0641\u0630 9444 (\u0648\u0627\u062c\u0647\u0629 data plane) \u063a\u064a\u0631 \u0645\u0641\u062a\u0648\u062d: \u0627\u0633\u0645\u062d \u0628\u0647 \u0641\u0642\u0637 \u0645\u0646 \u0639\u0642\u062f data plane \u0627\u0644\u062e\u0627\u0635\u0629 \u0628\u0643'
        'p_dpapi_only' = '9444/tcp \u0641\u0642\u0637 \u0645\u0646 data planes \u0627\u0644\u062e\u0627\u0635\u0629 \u0628\u0643\u060c \u0645\u062b\u0627\u0644:'
        'sum_setup_none' = '\u0644\u0627 \u064a\u0648\u062c\u062f \u0631\u0627\u0628\u0637 \u0625\u0639\u062f\u0627\u062f \u0647\u0630\u0647 \u0627\u0644\u0645\u0631\u0629 (\u0635\u062f\u0631 \u0633\u0627\u0628\u0642\u0627 \u0623\u0648 \u0627\u0644\u062d\u0633\u0627\u0628 \u0645\u0648\u062c\u0648\u062f). \u0644\u0625\u0646\u0634\u0627\u0621 \u0631\u0627\u0628\u0637 \u062c\u062f\u064a\u062f: toutwaf-cp setup-link --regenerate'
        'sum_ports' = '\u0627\u0644\u0645\u0646\u0627\u0641\u0630 \u0627\u0644\u0645\u0637\u0644\u0648\u0628 \u0641\u062a\u062d\u0647\u0627 \u0641\u064a \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629'
        'sum_cmds' = '\u0627\u0644\u0623\u0648\u0627\u0645\u0631'
        'sum_cloud' = '\u0627\u0644\u0633\u062d\u0627\u0628\u0629 / \u0627\u0644\u0627\u0633\u062a\u0636\u0627\u0641\u0629: \u0627\u0641\u062a\u062d \u0647\u0630\u0647 \u0627\u0644\u0645\u0646\u0627\u0641\u0630 \u0623\u064a\u0636\u0627 \u0641\u064a \u0645\u062c\u0645\u0648\u0639\u0629 \u0627\u0644\u0623\u0645\u0627\u0646 / \u0642\u0627\u0626\u0645\u0629 ACL \u0644\u062f\u0649 \u0627\u0644\u0645\u0632\u0648\u062f.'
        'sum_file' = '\u062a\u0645 \u062d\u0641\u0638 \u0627\u0644\u0645\u0644\u062e\u0635 (root \u0641\u0642\u0637): {0}'
        'sum_fallback' = '\u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u062a\u062d\u0643\u0645 \u0647\u0630\u0627 \u0644\u0627 \u064a\u062a\u0636\u0645\u0646 \u0623\u0645\u0631 ''bootstrap'' \u0628\u0639\u062f: \u0627\u0641\u062a\u062d \u0639\u0646\u0648\u0627\u0646 \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 \u0648\u0627\u062a\u0628\u0639 \u0635\u0641\u062d\u0629 \u0627\u0644\u0625\u0639\u062f\u0627\u062f.'
        'sum_node_hint' = '\u0644\u0625\u062f\u0627\u0631\u0629 \u0647\u0630\u0647 \u0627\u0644\u0639\u0642\u062f\u0629 \u0645\u0646 \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645: \u0627\u0644\u0639\u0642\u062f > \u0625\u0636\u0627\u0641\u0629 \u0639\u0642\u062f\u0629\u060c \u062b\u0645 \u0627\u0636\u0628\u0637 control_plane.url / enroll_token \u0641\u064a {0}.'
        'q_fwmodule' = '\u0647\u0644 \u062a\u0631\u064a\u062f \u0623\u0646 \u064a\u062f\u064a\u0631 ToutWAF \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629 \u0644\u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u0623\u064a\u0636\u0627\u061f'
        'fwmod_n1' = '\u0648\u062d\u062f\u0629 \u0627\u062e\u062a\u064a\u0627\u0631\u064a\u0629\u060c \u0645\u062a\u0648\u0642\u0641\u0629 \u0645\u0627 \u0644\u0645 \u062a\u062c\u0628 \u0628\u0646\u0639\u0645. \u0644\u0627 \u064a\u064f\u0637\u0628\u064e\u0651\u0642 \u0634\u064a\u0621 \u0623\u062b\u0646\u0627\u0621 \u0627\u0644\u062a\u062b\u0628\u064a\u062a: \u062a\u0631\u0627\u062c\u0639 \u0643\u0644 \u062a\u063a\u064a\u064a\u0631 \u0641\u064a \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645.'
        's_bkclient' = '\u062a\u062b\u0628\u064a\u062a \u0639\u0645\u064a\u0644 ToutWAF Backup (\u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u062a\u0648\u0642\u064a\u0639)'
        'bkc_done' = '\u062a\u0645 \u062a\u062b\u0628\u064a\u062a \u0639\u0645\u064a\u0644 ToutWAF Backup. \u0627\u0644\u062a\u0627\u0644\u064a: \u0627\u0644\u0648\u062d\u062f\u0629\u060c \u0627\u0644\u0646\u0633\u062e \u0627\u0644\u0627\u062d\u062a\u064a\u0627\u0637\u064a > \u062e\u0648\u0627\u062f\u0645 \u0627\u0644\u0646\u0633\u062e\u060c \u0644\u0631\u0628\u0637 \u062e\u0627\u062f\u0645.'
        'bkc_fail' = '\u0644\u0645 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a \u0639\u0645\u064a\u0644 ToutWAF Backup ({0}). \u064a\u0633\u062a\u0645\u0631 \u0627\u0644\u062a\u062b\u0628\u064a\u062a\u061b \u062b\u0628\u0651\u062a\u0647 \u0644\u0627\u062d\u0642\u0627 \u0628\u0627\u0633\u062a\u062e\u062f\u0627\u0645 --with-backup-client.'
        'bkc_nokey' = '\u0644\u0645 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a \u0639\u0645\u064a\u0644 ToutWAF Backup: \u0644\u0627 \u064a\u0648\u062c\u062f \u0645\u0641\u062a\u0627\u062d \u0639\u0627\u0645 \u0644\u0644\u0625\u0635\u062f\u0627\u0631. \u0645\u0631\u0651\u0631\u0647 \u0639\u0628\u0631 --backup-client-pubkey (\u0623\u0648 TOUTWAF_BACKUP_PUBKEY \u0623\u0648 \u0627\u0644\u0645\u0644\u0641 backup-release.pub \u0641\u064a \u0645\u062c\u0644\u062f \u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a)\u061b \u0644\u0627 \u064a\u064f\u062b\u0628\u064e\u0651\u062a \u0634\u064a\u0621 \u062f\u0648\u0646 \u062a\u0648\u0642\u064a\u0639 \u0645\u064f\u062a\u062d\u0642\u064e\u0651\u0642 \u0645\u0646\u0647.'
        'bkc_badsig' = '\u0644\u0645 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a \u0639\u0645\u064a\u0644 ToutWAF Backup: \u062a\u0648\u0642\u064a\u0639 \u0627\u0644\u0625\u0635\u062f\u0627\u0631 \u063a\u064a\u0631 \u0635\u0627\u0644\u062d. \u0644\u0645 \u064a\u064f\u062b\u0628\u064e\u0651\u062a \u0634\u064a\u0621.'
        'tele_on' = '\u0627\u0644\u0642\u064a\u0627\u0633 \u0639\u0646 \u0628\u064f\u0639\u062f: \u064a\u0634\u0627\u0631\u0643 ToutWAF \u0627\u0641\u062a\u0631\u0627\u0636\u064a\u064b\u0627 \u0645\u0639 \u0641\u0636\u0627\u0621 \u0627\u0644\u0646\u0627\u0634\u0631 (app.toutwaf.com) \u0627\u0644\u0647\u062c\u0645\u0627\u062a \u0627\u0644\u062a\u064a \u062d\u062c\u0628\u0647\u0627 (\u0639\u0646\u0648\u0627\u0646 \u0627\u0644\u0645\u0647\u0627\u062c\u0645 \u0648\u0627\u0644\u0628\u0644\u062f \u0648\u0646\u0648\u0639 \u0627\u0644\u0647\u062c\u0648\u0645 \u0648\u0627\u0644\u0642\u0627\u0639\u062f\u0629) \u0648\u0623\u0631\u0642\u0627\u0645\u064b\u0627 \u0645\u062c\u0645\u0651\u0639\u0629 \u0648\u0623\u0633\u0645\u0627\u0621 \u0645\u0636\u064a\u0641\u064a \u0627\u0644\u0645\u0648\u0627\u0642\u0639 \u0627\u0644\u0645\u062d\u0645\u064a\u0629. \u0644\u0627 \u0645\u062d\u062a\u0648\u0649 \u0627\u0644\u0637\u0644\u0628\u0627\u062a \u0623\u0628\u062f\u064b\u0627 \u0648\u0644\u0627 \u0627\u0644\u0632\u0648\u0627\u0631 \u0627\u0644\u0634\u0631\u0639\u064a\u064a\u0646. \u064a\u0645\u0643\u0646 \u0625\u064a\u0642\u0627\u0641\u0647 \u0628\u0646\u0642\u0631\u0629 \u0641\u064a \u0627\u0644\u0648\u062d\u062f\u0629 (\u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a\u060c \u0627\u0644\u062e\u0635\u0648\u0635\u064a\u0629 \u0648\u0627\u0644\u0642\u064a\u0627\u0633 \u0639\u0646 \u0628\u064f\u0639\u062f) \u0623\u0648 \u062b\u0628\u0651\u062a \u0645\u0639 --no-telemetry (\u0623\u0648 TOUTWAF_TELEMETRY=0) \u0644\u0644\u062d\u0635\u0648\u0644 \u0639\u0644\u0649 \u0642\u064a\u0627\u0633 \u0635\u0641\u0631\u064a. \u0627\u0644\u062a\u0641\u0627\u0635\u064a\u0644: docs/confidentialite-telemetrie.md'
        'tele_off' = '\u0627\u0644\u0642\u064a\u0627\u0633 \u0639\u0646 \u0628\u064f\u0639\u062f: \u0637\u064f\u0644\u0628 \u0627\u0644\u0642\u064a\u0627\u0633 \u0627\u0644\u0635\u0641\u0631\u064a (--no-telemetry / TOUTWAF_TELEMETRY=0). \u0644\u0646 \u064a\u064f\u0631\u0633\u0644 \u0634\u064a\u0621 \u0625\u0644\u0649 \u0641\u0636\u0627\u0621 \u0627\u0644\u0646\u0627\u0634\u0631 \u0648\u0644\u0646 \u064a\u064f\u0633\u062a\u0642\u0628\u0644 \u0645\u0646\u0647 \u0634\u064a\u0621\u060c \u0648\u062a\u0628\u062f\u0623 \u0627\u0644\u0648\u062d\u062f\u0629 \u0648\u0627\u0644\u0645\u0641\u062a\u0627\u062d \u00ab\u0627\u0644\u0642\u064a\u0627\u0633 \u0627\u0644\u0635\u0641\u0631\u064a\u00bb \u0645\u0641\u0639\u0651\u0644. \u064a\u0645\u0643\u0646\u0643 \u062a\u063a\u064a\u064a\u0631 \u0630\u0644\u0643 \u0644\u0627\u062d\u0642\u064b\u0627 \u0641\u064a \u0627\u0644\u0648\u062d\u062f\u0629 (\u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a\u060c \u0627\u0644\u062e\u0635\u0648\u0635\u064a\u0629 \u0648\u0627\u0644\u0642\u064a\u0627\u0633 \u0639\u0646 \u0628\u064f\u0639\u062f).'
        'fwmod_n2' = '\u0643\u0644 \u062a\u063a\u064a\u064a\u0631 \u064a\u0645\u0631 \u0628\u062a\u062c\u0631\u0628\u0629 \u0645\u0639 \u0639\u062f \u062a\u0646\u0627\u0632\u0644\u064a \u0648\u064a\u062a\u0631\u0627\u062c\u0639 \u062a\u0644\u0642\u0627\u0626\u064a\u0627 \u0645\u0627 \u0644\u0645 \u062a\u062d\u062a\u0641\u0638 \u0628\u0647\u061b \u0648\u062a\u0645\u0646\u0639 \u062d\u0645\u0627\u064a\u0629 \u0645\u0636\u0627\u062f\u0629 \u0644\u0644\u0625\u0642\u0641\u0627\u0644 \u0623\u064a \u0642\u0627\u0639\u062f\u0629 \u0642\u062f \u062a\u0642\u0637\u0639 SSH \u0623\u0648 \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645.'
        'fwmod_n3' = '\u0647\u0630\u0627 \u0644\u064a\u0633 \u0627\u0644\u0633\u0624\u0627\u0644 \u0627\u0644\u0633\u0627\u0628\u0642 \u0627\u0644\u0630\u064a \u064a\u0641\u062a\u062d \u0641\u0642\u0637 \u0627\u0644\u0645\u0646\u0627\u0641\u0630 \u0627\u0644\u062a\u064a \u064a\u062d\u062a\u0627\u062c\u0647\u0627 ToutWAF \u0641\u064a \u062c\u062f\u0627\u0631 \u062d\u0645\u0627\u064a\u0629 \u0627\u0644\u0646\u0638\u0627\u0645 (--no-firewall).'
        's_fwmod' = '\u062a\u0641\u0639\u064a\u0644 \u0648\u062d\u062f\u0629 \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629 (\u062f\u0648\u0646 \u062a\u0637\u0628\u064a\u0642 \u0623\u064a \u0642\u0627\u0639\u062f\u0629)'
        'fwmod_done' = '\u062a\u0645 \u062a\u0641\u0639\u064a\u0644 \u0648\u062d\u062f\u0629 \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629. \u0644\u0645 \u064a\u064f\u0637\u0628\u064e\u0651\u0642 \u0634\u064a\u0621: \u0627\u0641\u062a\u062d \u00ab\u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629\u00bb \u0641\u064a \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 \u0644\u0645\u0631\u0627\u062c\u0639\u0629 \u0627\u0644\u0642\u0648\u0627\u0639\u062f \u0648\u062a\u062c\u0631\u0628\u062a\u0647\u0627.'
        'fwmod_fail' = '\u062a\u0639\u0630\u0651\u0631 \u062a\u0641\u0639\u064a\u0644 \u0648\u062d\u062f\u0629 \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629 ({0}). \u064a\u0633\u062a\u0645\u0631 \u0627\u0644\u062a\u062b\u0628\u064a\u062a\u061b \u0641\u0639\u0651\u0644\u0647\u0627 \u0644\u0627\u062d\u0642\u0627 \u0645\u0646 \u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a > \u0627\u0644\u0648\u062d\u062f\u0627\u062a.'
        's_link' = '\u0631\u0628\u0637 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0628\u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645'
        'dp_link_ok' = '\u062a\u0645 \u0631\u0628\u0637 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0628\u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 \u062a\u0644\u0642\u0627\u0626\u064a\u064b\u0627: \u0644\u0627 \u0634\u064a\u0621 \u0644\u0636\u0628\u0637\u0647 \u064a\u062f\u0648\u064a\u064b\u0627.'
        'dp_link_same' = '\u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0645\u0631\u062a\u0628\u0637 \u0628\u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 \u0628\u0627\u0644\u0641\u0639\u0644\u061b \u0644\u0645 \u064a\u062a\u0645 \u062a\u0639\u062f\u064a\u0644 \u062a\u0643\u0648\u064a\u0646\u0647.'
        'dp_link_fixed' = '\u062a\u0645 \u0625\u0635\u0644\u0627\u062d \u062a\u0643\u0648\u064a\u0646 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a (\u062f\u064f\u0645\u062c\u062a \u0643\u062a\u0644 control_plane \u0627\u0644\u0645\u0643\u0631\u0631\u0629 \u0641\u064a \u0643\u062a\u0644\u0629 \u0648\u0627\u062d\u062f\u0629)\u061b \u062a\u0645 \u0627\u0644\u0627\u062d\u062a\u0641\u0627\u0638 \u0628\u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0633\u0627\u0628\u0642.'
        'dp_link_remote' = '\u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u0645\u0636\u0628\u0648\u0637 \u0644\u0644\u0639\u0645\u0644 \u0645\u0639 \u0644\u0648\u062d\u0629 \u062a\u062d\u0643\u0645 \u0623\u062e\u0631\u0649\u061b \u0644\u0645 \u064a\u062a\u0645 \u062a\u0639\u062f\u064a\u0644\u0647.'
        'dp_link_fail' = '\u062a\u0639\u0630\u0651\u0631 \u0631\u0628\u0637 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0628\u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645 \u062a\u0644\u0642\u0627\u0626\u064a\u064b\u0627: {0}'
        'dp_link_fail_hint' = '\u064a\u062d\u062a\u0641\u0638 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0628\u062a\u0643\u0648\u064a\u0646\u0647 \u0627\u0644\u0645\u0633\u062a\u0642\u0644\u060c \u0644\u0630\u0627 \u062a\u0631\u062f\u0651 \u0627\u0644\u0645\u0648\u0627\u0642\u0639 \u0628\u0627\u0644\u0631\u0645\u0632 HTTP 421 \u0625\u0644\u0649 \u0623\u0646 \u064a\u062a\u0645 \u0631\u0628\u0637\u0647. \u0623\u0635\u0644\u062d \u0627\u0644\u0633\u0628\u0628 \u0623\u0639\u0644\u0627\u0647 \u0648\u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0647\u0630\u0627 \u0627\u0644\u0645\u062b\u0628\u0651\u062a: \u0641\u0647\u0648 \u064a\u0631\u0628\u0637 \u0627\u0644\u0639\u0642\u062f\u0629 \u0628\u0646\u0641\u0633\u0647.'
        'st_title' = '\u0627\u0644\u062d\u0627\u0644\u0629'
        'st_healthy' = '\u0633\u0644\u064a\u0645'
        'st_unhealthy' = '\u063a\u064a\u0631 \u0633\u0644\u064a\u0645'
        'st_active' = '\u0646\u0634\u0637'
        'st_inactive' = '\u063a\u064a\u0631 \u0646\u0634\u0637'
        'st_listening' = '\u064a\u0633\u062a\u0645\u0639'
        'st_closed' = '\u0644\u0627 \u064a\u0633\u062a\u0645\u0639'
        'un_title' = '\u062c\u0627\u0631 \u0625\u0632\u0627\u0644\u0629 ToutWAF'
        'un_kept' = '\u062a\u0645 \u0627\u0644\u0627\u062d\u062a\u0641\u0627\u0638 \u0628\u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a \u0641\u064a {0} \u0648\u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0641\u064a {1} (\u0627\u0633\u062a\u062e\u062f\u0645 --purge \u0644\u0644\u062d\u0630\u0641).'
        'un_purged' = '\u062a\u0645 \u062d\u0630\u0641 \u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a \u0648\u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0648\u0627\u0644\u0633\u062c\u0644\u0627\u062a.'
        'p_console' = '\u0648\u062d\u062f\u0629 \u062a\u062d\u0643\u0645 \u0627\u0644\u0648\u064a\u0628 + API'
        'p_http' = 'HTTP (\u0648\u0643\u064a\u0644 \u0639\u0643\u0633\u064a)'
        'p_https' = 'HTTPS (\u0648\u0643\u064a\u0644 \u0639\u0643\u0633\u064a)'
        'p_dpapi' = '\u0648\u0627\u062c\u0647\u0629 API \u0644\u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a: \u0641\u0642\u0637 \u0625\u0630\u0627 \u0643\u0627\u0646\u062a \u0645\u0633\u062a\u0648\u064a\u0627\u062a \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0639\u0644\u0649 \u0645\u0636\u064a\u0641\u0627\u062a \u0623\u062e\u0631\u0649 (\u0642\u064a\u0651\u062f\u0647\u0627 \u0628\u0639\u0646\u0627\u0648\u064a\u0646\u0647\u0627)'
        'w_fw_manual' = '\u0644\u0645 \u064a\u062a\u0645 \u0641\u062a\u062d \u0627\u0644\u0645\u0646\u0641\u0630 {0}/tcp \u062a\u0644\u0642\u0627\u0626\u064a\u0627: \u0631\u0627\u062c\u0639 \u0627\u0644\u0623\u0648\u0627\u0645\u0631 \u0641\u064a \u0627\u0644\u0645\u0644\u062e\u0635.'
        'need_cp' = '\u064a\u0644\u0632\u0645 \u0639\u0646\u0648\u0627\u0646 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u062a\u062d\u0643\u0645 \u0639\u0646\u062f \u062a\u0642\u062f\u064a\u0645 \u0631\u0645\u0632 \u0627\u0644\u062a\u0633\u062c\u064a\u0644.'
        'cp_title' = '\u062a\u0648\u0627\u0641\u0642 \u0627\u0644\u0646\u0638\u0627\u0645'
        'cp_detected' = '\u062a\u0645 \u0627\u0644\u0643\u0634\u0641: {0}\u060c \u0627\u0644\u0645\u0639\u0645\u0627\u0631\u064a\u0629 {1}\u060c glibc {2}\u060c systemd {3}\u060c \u0627\u0644\u0646\u0648\u0627\u0629 {4}'
        'cp_ok' = '\u0645\u062a\u0648\u0627\u0641\u0642: {0} ({1})'
        'cp_tested' = '\u062a\u0645 \u0627\u062e\u062a\u0628\u0627\u0631\u0647'
        'cp_expected' = '\u0645\u062a\u0648\u0642\u0639'
        'cp_w_like' = '{0} \u063a\u064a\u0631 \u0645\u0648\u062c\u0648\u062f \u0641\u064a \u062c\u062f\u0648\u0644 \u0627\u0644\u062a\u0648\u0627\u0641\u0642: \u064a\u064f\u0639\u0627\u0645\u0644 \u0643\u0639\u0627\u0626\u0644\u0629 {1} (\u0645\u062a\u0648\u0642\u0639). \u0627\u0644\u0645\u062a\u0627\u0628\u0639\u0629.'
        'cp_w_newer' = '{0} {1} \u0623\u062d\u062f\u062b \u0645\u0646 \u0627\u0644\u0625\u0635\u062f\u0627\u0631\u0627\u062a \u0627\u0644\u0645\u062f\u0631\u062c\u0629: \u0644\u0645 \u064a\u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646\u0647 \u0628\u0639\u062f (\u0645\u062a\u0648\u0642\u0639). \u0627\u0644\u0645\u062a\u0627\u0628\u0639\u0629.'
        'cp_w_unlisted' = '{0} {1} \u063a\u064a\u0631 \u0645\u062f\u0631\u062c \u0641\u064a \u0627\u0644\u062c\u062f\u0648\u0644: \u064a\u064f\u0639\u0627\u0645\u0644 \u0643\u0645\u062a\u0648\u0642\u0639. \u0627\u0644\u0645\u062a\u0627\u0628\u0639\u0629.'
        'cp_w_nover' = '{0} \u0644\u0627 \u064a\u0639\u0644\u0646 \u0639\u0646 \u0625\u0635\u062f\u0627\u0631 (\u062a\u062d\u062f\u064a\u062b \u0645\u0633\u062a\u0645\u0631 \u0623\u0648 \u0627\u062e\u062a\u0628\u0627\u0631\u064a): \u064a\u064f\u0639\u0627\u0645\u0644 \u0643\u0645\u062a\u0648\u0642\u0639. \u0627\u0644\u0645\u062a\u0627\u0628\u0639\u0629.'
        'cp_w_glibc' = '\u062a\u0639\u0630\u0631 \u062a\u062d\u062f\u064a\u062f \u0625\u0635\u062f\u0627\u0631 glibc\u061b \u0627\u0644\u0645\u062a\u0627\u0628\u0639\u0629.'
        'cp_w_skip' = '--skip-os-check: \u062a\u0645 \u062a\u062c\u0627\u0648\u0632 \u0641\u062d\u0635 \u0627\u0644\u062a\u0648\u0627\u0641\u0642. \u0647\u0630\u0627 \u0627\u0644\u0646\u0638\u0627\u0645 \u063a\u064a\u0631 \u0645\u062f\u0639\u0648\u0645: \u0627\u0644\u0645\u062a\u0627\u0628\u0639\u0629 \u0639\u0644\u0649 \u0645\u0633\u0624\u0648\u0644\u064a\u062a\u0643.'
        'cp_w_stage' = '\u0627\u0644\u062a\u062c\u0647\u064a\u0632 (--destdir): \u0646\u062a\u064a\u062c\u0629 \u0627\u0644\u062a\u0648\u0627\u0641\u0642 \u0644\u0644\u0639\u0644\u0645 \u0641\u0642\u0637 \u0648\u0644\u0627 \u064a\u064f\u0631\u0641\u0636 \u0634\u064a\u0621.'
        'cp_refused' = '\u0647\u0630\u0627 \u0627\u0644\u0646\u0638\u0627\u0645 \u063a\u064a\u0631 \u0645\u062a\u0648\u0627\u0641\u0642 \u0645\u0639 ToutWAF:'
        'cp_r_old' = '{0} {1} \u0623\u0642\u062f\u0645 \u0645\u0646 \u0627\u0644\u062d\u062f \u0627\u0644\u0623\u062f\u0646\u0649 \u0644\u0644\u0625\u0635\u062f\u0627\u0631 \u0627\u0644\u0645\u062f\u0639\u0648\u0645 ({2}).'
        'cp_r_eol' = '{0} {1} \u0627\u0646\u062a\u0647\u0649 \u0639\u0645\u0631\u0647 \u0623\u0648 \u0623\u0646 glibc / systemd \u0641\u064a\u0647 \u0642\u062f\u064a\u0645 \u062c\u062f\u0627.'
        'cp_r_glibc' = '\u062a\u0645 \u0627\u0644\u0639\u062b\u0648\u0631 \u0639\u0644\u0649 glibc {0}: \u0645\u0637\u0644\u0648\u0628 {1} \u0623\u0648 \u0623\u062d\u062f\u062b.'
        'cp_r_musl' = '\u062a\u0645 \u0627\u0644\u0639\u062b\u0648\u0631 \u0639\u0644\u0649 musl libc: \u0645\u0637\u0644\u0648\u0628 glibc {0} \u0623\u0648 \u0623\u062d\u062f\u062b.'
        'cp_r_init' = '{0} {1} \u0644\u0627 \u064a\u0633\u062a\u062e\u062f\u0645 systemd \u0627\u0644\u0630\u064a \u064a\u062a\u0637\u0644\u0628\u0647 ToutWAF.'
        'cp_r_immutable' = '{0} {1} \u064a\u0633\u062a\u062e\u062f\u0645 \u0646\u0638\u0627\u0645 \u0645\u0644\u0641\u0627\u062a \u062c\u0630\u0631 \u063a\u064a\u0631 \u0642\u0627\u0628\u0644 \u0644\u0644\u062a\u0639\u062f\u064a\u0644 (\u063a\u064a\u0631 \u0645\u062f\u0639\u0648\u0645).'
        'cp_r_layout' = '{0} {1} \u0644\u0627 \u064a\u062a\u0628\u0639 \u0628\u0646\u064a\u0629 \u0645\u0644\u0641\u0627\u062a Linux \u0627\u0644\u0642\u064a\u0627\u0633\u064a\u0629 (\u063a\u064a\u0631 \u0645\u062f\u0639\u0648\u0645).'
        'cp_r_arch' = '\u0627\u0644\u0645\u0639\u0645\u0627\u0631\u064a\u0629 {0} \u063a\u064a\u0631 \u0645\u062f\u0639\u0648\u0645\u0629 (\u0627\u0644\u0645\u062f\u0639\u0648\u0645: {1}).'
        'cp_r_distro_arch' = '{0} {1} \u064a\u0639\u0645\u0644 \u0639\u0644\u0649 \u0645\u0639\u0645\u0627\u0631\u064a\u0629 \u0628\u0644\u0627 \u0625\u0635\u062f\u0627\u0631 \u0645\u0646 ToutWAF.'
        'cp_r_systemd' = 'systemd \u0644\u0627 \u064a\u0639\u0645\u0644 \u0643\u0646\u0638\u0627\u0645 init (\u0627\u0644\u0645\u062c\u0644\u062f /run/systemd/system \u063a\u064a\u0631 \u0645\u0648\u062c\u0648\u062f): \u0645\u0637\u0644\u0648\u0628 \u0644\u0644\u062e\u062f\u0645\u0627\u062a.'
        'cp_r_systemd_old' = '\u062a\u0645 \u0627\u0644\u0639\u062b\u0648\u0631 \u0639\u0644\u0649 systemd {0}: \u0645\u0637\u0644\u0648\u0628 {1} \u0623\u0648 \u0623\u062d\u062f\u062b.'
        'cp_r_kernel' = '\u062a\u0645 \u0627\u0644\u0639\u062b\u0648\u0631 \u0639\u0644\u0649 \u0646\u0648\u0627\u0629 Linux {0}: \u0645\u0637\u0644\u0648\u0628 {1} \u0623\u0648 \u0623\u062d\u062f\u062b.'
        'cp_r_unknown' = '\u0627\u0644\u062a\u0648\u0632\u064a\u0639\u0629 ''{0}'' \u063a\u064a\u0631 \u0645\u0639\u0631\u0648\u0641\u0629 \u0648\u0644\u0627 \u062a\u0639\u0644\u0646 \u0639\u0646 \u0639\u0627\u0626\u0644\u0629 \u0645\u0639\u0631\u0648\u0641\u0629 (ID_LIKE=''{1}'').'
        'cp_r_noosr' = '\u0627\u0644\u0645\u0644\u0641 /etc/os-release \u063a\u064a\u0631 \u0645\u0648\u062c\u0648\u062f: \u0644\u0627 \u064a\u0645\u0643\u0646 \u062a\u062d\u062f\u064a\u062f \u0627\u0644\u062a\u0648\u0632\u064a\u0639\u0629.'
        'cp_nochange' = '\u0644\u0645 \u064a\u062a\u0645 \u062a\u063a\u064a\u064a\u0631 \u0623\u064a \u0634\u064a\u0621 \u0641\u064a \u0647\u0630\u0627 \u0627\u0644\u0646\u0638\u0627\u0645.'
        'cp_list' = '\u0627\u0644\u0623\u0646\u0638\u0645\u0629 \u0627\u0644\u0645\u062a\u0648\u0627\u0641\u0642\u0629 (amd64 \u0648arm64\u060c glibc {0} \u0623\u0648 \u0623\u062d\u062f\u062b\u060c systemd {1} \u0623\u0648 \u0623\u062d\u062f\u062b):'
        'cp_rolling' = '\u062a\u062d\u062f\u064a\u062b \u0645\u0633\u062a\u0645\u0631'
        'cp_any' = '\u0623\u064a \u0625\u0635\u062f\u0627\u0631'
        'cp_override' = '\u0644\u0644\u062a\u062b\u0628\u064a\u062a \u0631\u063a\u0645 \u0630\u0644\u0643 \u0639\u0644\u0649 \u0645\u0633\u0624\u0648\u0644\u064a\u062a\u0643: --skip-os-check. \u0627\u0644\u062a\u0641\u0627\u0635\u064a\u0644: docs/install/platforms.md'
        'cp_not_root' = '\u0644\u0627 \u064a\u0639\u0645\u0644 \u0643\u0645\u0633\u062a\u062e\u062f\u0645 root: \u0627\u0633\u062a\u062e\u062f\u0645 sudo \u0644\u0644\u062a\u062b\u0628\u064a\u062a (\u0627\u0644\u0641\u062d\u0635 \u0646\u0641\u0633\u0647 \u0644\u0627 \u064a\u062d\u062a\u0627\u062c root).'
        'sum_compat' = '\u0627\u0644\u062a\u0648\u0627\u0641\u0642'
        'cp_prereq_arch' = '\u0642\u0648\u0627\u0639\u062f \u0628\u064a\u0627\u0646\u0627\u062a \u0627\u0644\u062d\u0632\u0645 \u063a\u064a\u0631 \u0645\u062a\u0632\u0627\u0645\u0646\u0629. \u0634\u063a\u0651\u0644 ''pacman -Syu'' \u0623\u0648\u0644\u0627 (\u0627\u0644\u062a\u062d\u062f\u064a\u062b \u0627\u0644\u062c\u0632\u0626\u064a \u063a\u064a\u0631 \u0645\u062f\u0639\u0648\u0645 \u0641\u064a Arch) \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u062b\u0628\u062a.'
        'cp_wdetected' = '\u062a\u0645 \u0627\u0644\u0643\u0634\u0641: {0} (\u0627\u0644\u0628\u0646\u064a\u0629 {1})\u060c \u0627\u0644\u0645\u0639\u0645\u0627\u0631\u064a\u0629 {2}'
        'cp_wlist' = '\u0625\u0635\u062f\u0627\u0631\u0627\u062a Windows \u0627\u0644\u0645\u062a\u0648\u0627\u0641\u0642\u0629 (amd64 \u0648arm64\u061b arm64 \u0644\u0645 \u064a\u064f\u062e\u062a\u0628\u0631 \u0639\u0644\u0649 \u0623\u062c\u0647\u0632\u0629 \u062d\u0642\u064a\u0642\u064a\u0629):'
        'cp_r_arm32' = 'ToutWAF \u0644\u0627 \u064a\u062f\u0639\u0645 ARM \u0628\u0646\u0638\u0627\u0645 32 \u0628\u062a (armv7). \u062b\u0628\u0651\u062a \u0646\u0638\u0627\u0645\u0627 \u0628\u0646\u0638\u0627\u0645 64 \u0628\u062a (Raspberry Pi OS 64 \u0628\u062a \u0623\u0648 Ubuntu \u0623\u0648 Debian arm64\u061b Raspberry Pi 3 \u0623\u0648 4 \u0623\u0648 5 \u0623\u0648 Zero 2 W) \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u062b\u0628\u062a.'
        'cp_r_arm_userland32' = '\u0627\u0644\u0646\u0648\u0627\u0629 64 \u0628\u062a \u0644\u0643\u0646 \u0627\u0644\u0646\u0638\u0627\u0645 (userland) 32 \u0628\u062a. \u064a\u062d\u062a\u0627\u062c ToutWAF \u0625\u0644\u0649 \u0646\u0638\u0627\u0645 64 \u0628\u062a: \u0623\u0639\u062f \u0627\u0644\u062a\u062b\u0628\u064a\u062a \u0628\u0627\u0633\u062a\u062e\u062f\u0627\u0645 Raspberry Pi OS 64 \u0628\u062a (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) \u0623\u0648 Ubuntu / Debian arm64.'
        'cp_w_pi' = '\u062a\u0645 \u0627\u0643\u062a\u0634\u0627\u0641 Raspberry Pi: \u0644\u0645 \u062a\u064f\u062e\u062a\u0628\u0631 arm64 \u0625\u0644\u0627 \u062a\u062d\u062a \u0627\u0644\u0645\u062d\u0627\u0643\u0627\u0629 \u0648\u0644\u064a\u0633 \u0639\u0644\u0649 \u0623\u062c\u0647\u0632\u0629 \u062d\u0642\u064a\u0642\u064a\u0629. \u0636\u0639 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0648\u0627\u0644\u0633\u062c\u0644\u0627\u062a \u0639\u0644\u0649 SSD / \u0642\u0631\u0635 USB \u0628\u062f\u0644\u0627 \u0645\u0646 \u0628\u0637\u0627\u0642\u0629 SD \u0648\u062a\u062c\u0646\u0628 \u0627\u0644\u062a\u062b\u0628\u064a\u062a \u0627\u0644\u0634\u0627\u0645\u0644 \u0628\u0623\u0642\u0644 \u0645\u0646 2 \u062c\u064a\u062c\u0627\u0628\u0627\u064a\u062a \u0645\u0646 \u0627\u0644\u0630\u0627\u0643\u0631\u0629 (\u0631\u0627\u062c\u0639 docs/install/raspberry-pi.md).'
        'pf_title' = '\u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0645\u0627 \u064a\u062d\u062a\u0627\u062c\u0647 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632'
        'pf_ok' = '\u0644\u0627 \u0634\u064a\u0621 \u064a\u0639\u064a\u0642: \u0627\u0644\u0645\u0646\u0627\u0641\u0630 \u0627\u0644\u062a\u064a \u064a\u062d\u062a\u0627\u062c\u0647\u0627 ToutWAF \u062d\u0631\u0629.'
        'pf_refused' = '\u0644\u0627 \u064a\u0645\u0643\u0646 \u062a\u062b\u0628\u064a\u062a ToutWAF \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u0628\u062d\u0627\u0644\u062a\u0647 \u0627\u0644\u062d\u0627\u0644\u064a\u0629. \u0644\u0645 \u064a\u062a\u063a\u064a\u0631 \u0634\u064a\u0621.'
        'pf_ok_warn' = '\u0644\u0627 \u0634\u064a\u0621 \u064a\u0645\u0646\u0639 \u0627\u0644\u062a\u062b\u0628\u064a\u062a\u060c \u0644\u0643\u0646 \u0627\u0642\u0631\u0623 \u0627\u0644\u0646\u0642\u0627\u0637 \u0623\u0639\u0644\u0627\u0647.'
        'pf_l_refuse' = '\u0645\u0631\u0641\u0648\u0636'
        'pf_l_warn' = '\u062a\u0646\u0628\u064a\u0647'
        'pf_l_info' = '\u0645\u0644\u0627\u062d\u0638\u0629'
        'pf_port_busy' = '\u0627\u0644\u0645\u0646\u0641\u0630 {0} \u0645\u0633\u062a\u062e\u062f\u0645 \u0628\u0627\u0644\u0641\u0639\u0644 \u0645\u0646 {1}.'
        'pf_prog_other' = '\u0628\u0631\u0646\u0627\u0645\u062c \u0622\u062e\u0631'
        'pf_prog_unknown' = '\u0628\u0631\u0646\u0627\u0645\u062c \u0622\u062e\u0631 (\u062a\u0639\u0630\u0651\u0631\u062a \u0642\u0631\u0627\u0621\u0629 \u0627\u0633\u0645\u0647)'
        'pf_act_web' = '\u064a\u062d\u062a\u0627\u062c ToutWAF \u0625\u0644\u0649 \u0627\u0644\u0645\u0646\u0641\u0630\u064a\u0646 {0} \u0648{1} \u0644\u062d\u0645\u0627\u064a\u0629 \u0645\u0648\u0627\u0642\u0639\u0643. \u0623\u0648\u0642\u0641 \u0647\u0630\u0627 \u0627\u0644\u0628\u0631\u0646\u0627\u0645\u062c \u0623\u0648 \u0627\u0646\u0642\u0644\u0647 \u0625\u0644\u0649 \u0645\u0646\u0627\u0641\u0630 \u0623\u062e\u0631\u0649 (\u064a\u0636\u0639 ToutPanel \u0627\u0644\u0645\u062b\u0628\u0651\u062a \u0628\u062c\u0627\u0646\u0628 ToutWAF \u062e\u0627\u062f\u0645 \u0627\u0644\u0648\u064a\u0628 \u0627\u0644\u062e\u0627\u0635 \u0628\u0647 \u0639\u0644\u0649 8080 \u06488443) \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u062b\u0628\u062a.'
        'pf_act_console' = '\u062a\u062d\u062a\u0627\u062c \u0644\u0648\u062d\u0629 \u062a\u062d\u0643\u0645 ToutWAF \u0625\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u0645\u0646\u0641\u0630. \u062d\u0631\u0651\u0631\u0647 \u0623\u0648 \u0627\u062e\u062a\u0631 \u0645\u0646\u0641\u0630\u064b\u0627 \u0622\u062e\u0631 \u0644\u0644\u0648\u062d\u0629 (\u064a\u0633\u0623\u0644 \u0627\u0644\u0645\u062b\u0628\u062a \u0639\u0646\u0647 \u0641\u064a \u0642\u0627\u0626\u0645\u062a\u0647) \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u062b\u0628\u062a.'
        'pf_act_agent' = '\u064a\u0633\u062a\u062e\u062f\u0645 ToutWAF \u0647\u0630\u0627 \u0627\u0644\u0645\u0646\u0641\u0630 \u0644\u0645\u0633\u062a\u0648\u064a\u0627\u062a \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0648\u0627\u0644\u0648\u0643\u0644\u0627\u0621 \u0627\u0644\u0645\u062a\u0635\u0644\u064a\u0646 \u0628\u0647. \u062d\u0631\u0651\u0631\u0647 \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u062b\u0628\u062a.'
        'pf_act_admin' = '\u064a\u0633\u062a\u062e\u062f\u0645 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0647\u0630\u0627 \u0627\u0644\u0645\u0646\u0641\u0630 \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u0641\u0642\u0637 \u0644\u0641\u062d\u0635 \u062d\u0627\u0644\u062a\u0647. \u062d\u0631\u0651\u0631\u0647 \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u062b\u0628\u062a.'
        'pf_nostart' = '(\u0644\u0646 \u064a\u064f\u0634\u063a\u064e\u0651\u0644 \u0634\u064a\u0621 \u0627\u0644\u0622\u0646\u060c \u0644\u0630\u0644\u0643 \u064a\u064f\u0643\u062a\u0641\u0649 \u0628\u0627\u0644\u062a\u0646\u0628\u064a\u0647)'
        'pf_boot' = '{0} \u0645\u062b\u0628\u0651\u062a \u0648\u064a\u0628\u062f\u0623 \u0645\u0639 \u0627\u0644\u062c\u0647\u0627\u0632 \u0631\u063a\u0645 \u0623\u0646\u0647 \u0645\u062a\u0648\u0642\u0641 \u0627\u0644\u0622\u0646. \u0639\u0646\u062f \u0625\u0639\u0627\u062f\u0629 \u0627\u0644\u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u062a\u0627\u0644\u064a\u0629 \u0633\u064a\u062d\u062c\u0632 \u0627\u0644\u0645\u0646\u0641\u0630\u064a\u0646 {1} \u0648{2} \u0642\u0628\u0644 ToutWAF.'
        'pf_act_boot' = '\u0639\u0637\u0651\u0644 \u062a\u0634\u063a\u064a\u0644\u0647 \u0645\u0639 \u0627\u0644\u062c\u0647\u0627\u0632 \u0623\u0648 \u0627\u0646\u0642\u0644\u0647 \u0625\u0644\u0649 \u0645\u0646\u0627\u0641\u0630 \u0623\u062e\u0631\u0649 \u0642\u0628\u0644 \u0625\u0639\u0627\u062f\u0629 \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u062c\u0647\u0627\u0632.'
        'pf_fw_cause' = '\u062c\u062f\u0627\u0631 \u062d\u0645\u0627\u064a\u0629 ({0}) \u0646\u0634\u0637 \u0648\u0644\u0627 \u064a\u0633\u0645\u062d \u0628\u0645\u0631\u0648\u0631 \u0627\u0644\u0645\u0646\u0641\u0630\u064a\u0646 {1} \u0648{2}\u060c \u0648\u0642\u062f \u0637\u064f\u0644\u0628 \u0645\u0646 \u0627\u0644\u0645\u062b\u0628\u062a \u0623\u0644\u0627 \u064a\u063a\u064a\u0651\u0631\u0647.'
        'pf_fw_action' = '\u0627\u0641\u062a\u062d \u0647\u0630\u064a\u0646 \u0627\u0644\u0645\u0646\u0641\u0630\u064a\u0646 \u0641\u064a \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629 \u0623\u0648 \u062f\u0639 \u0627\u0644\u0645\u062b\u0628\u062a \u064a\u0641\u0639\u0644 \u0630\u0644\u0643 (\u0628\u062f\u0648\u0646 \u0627\u0644\u062e\u064a\u0627\u0631 --no-firewall). \u0648\u0625\u0644\u0627 \u0641\u0644\u0646 \u062a\u0643\u0648\u0646 \u0645\u0648\u0627\u0642\u0639\u0643 \u0642\u0627\u0628\u0644\u0629 \u0644\u0644\u0648\u0635\u0648\u0644 \u0645\u0646 \u0627\u0644\u062e\u0627\u0631\u062c.'
        'pf_fwx_cause' = '\u062c\u062f\u0627\u0631 \u062d\u0645\u0627\u064a\u0629 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 ({0}) \u064a\u0631\u0641\u0636 \u0627\u0644\u0627\u062a\u0635\u0627\u0644\u0627\u062a \u0627\u0644\u0648\u0627\u0631\u062f\u0629 \u0627\u0641\u062a\u0631\u0627\u0636\u064a\u064b\u0627 \u0648\u0644\u064a\u0633 \u0641\u064a\u0647 \u0642\u0627\u0639\u062f\u0629 \u0644\u0644\u0645\u0646\u0641\u0630\u064a\u0646 {1} \u0648{2}.'
        'pf_fwx_action' = '\u0644\u0627 \u064a\u0639\u062f\u0651\u0644 ToutWAF \u0628\u0646\u0641\u0633\u0647 \u0623\u0628\u062f\u064b\u0627 \u0642\u0648\u0627\u0639\u062f \u0647\u0630\u0627 \u0627\u0644\u0646\u0648\u0639 \u0645\u0646 \u062c\u062f\u0631\u0627\u0646 \u0627\u0644\u062d\u0645\u0627\u064a\u0629: \u0627\u0641\u062a\u062d \u0647\u0630\u064a\u0646 \u0627\u0644\u0645\u0646\u0641\u0630\u064a\u0646 \u0641\u064a \u0625\u0639\u062f\u0627\u062f\u0627\u062a\u0647 \u062b\u0645 \u062a\u062d\u0642\u0642 \u0645\u0646 \u0645\u0648\u0627\u0642\u0639\u0643.'
        'pf_cp_cause' = '\u062a\u0639\u0630\u0651\u0631 \u0627\u0644\u0648\u0635\u0648\u0644 \u0625\u0644\u0649 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u062a\u062d\u0643\u0645 {0} \u0645\u0646 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632.'
        'pf_cp_action' = '\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u0639\u0646\u0648\u0627\u0646 \u0648\u0645\u0646 \u0623\u0646 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u062a\u062d\u0643\u0645 \u064a\u0639\u0645\u0644 \u0648\u0623\u0646 \u062c\u062f\u0627\u0631 \u0627\u0644\u062d\u0645\u0627\u064a\u0629 \u0641\u064a\u0647 \u064a\u0633\u0645\u062d \u0644\u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u0628\u0627\u0644\u0648\u0635\u0648\u0644 \u0625\u0644\u064a\u0647 (\u0627\u0644\u0645\u0646\u0641\u0630 9444 \u0627\u0641\u062a\u0631\u0627\u0636\u064a\u064b\u0627) \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u062b\u0628\u062a.'
        'pf_router_cause' = '\u0644\u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u0639\u0646\u0648\u0627\u0646 \u062e\u0627\u0635 ({0}): \u0645\u0646 \u0627\u0644\u0645\u0631\u062c\u062d \u0623\u0646\u0647 \u062e\u0644\u0641 \u0631\u0627\u0648\u062a\u0631.'
        'pf_router_action' = '\u0628\u0639\u062f \u0627\u0644\u062a\u062b\u0628\u064a\u062a \u0633\u064a\u0639\u0631\u0636 ToutWAF \u0627\u0644\u0645\u0646\u0627\u0641\u0630 \u0627\u0644\u062a\u064a \u064a\u062c\u0628 \u062a\u0648\u062c\u064a\u0647\u0647\u0627 \u0625\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u0648\u064a\u0642\u062f\u0651\u0645 \u0645\u0644\u0641\u0627\u062a \u0644\u0644\u0631\u0627\u0648\u062a\u0631\u0627\u062a \u0627\u0644\u0634\u0627\u0626\u0639\u0629. \u0644\u0627 \u0634\u064a\u0621 \u064a\u0644\u0632\u0645 \u062a\u062d\u0636\u064a\u0631\u0647 \u0627\u0644\u0622\u0646.'
        'pf_skipped' = '\u062a\u0645 \u062a\u062e\u0637\u064a \u0641\u062d\u0635 \u0627\u0644\u0628\u064a\u0626\u0629 \u0628\u0646\u0627\u0621\u064b \u0639\u0644\u0649 \u0637\u0644\u0628\u0643: \u0645\u0627 \u064a\u0639\u064a\u0642 \u0633\u064a\u0624\u062f\u064a \u0625\u0644\u0649 \u0641\u0634\u0644 \u0627\u0644\u062a\u062b\u0628\u064a\u062a \u0623\u0648 \u0627\u0644\u062a\u0634\u063a\u064a\u0644 \u0644\u0627\u062d\u0642\u064b\u0627.'
        's_sysupdate' = '\u062c\u0627\u0631\u064d \u062a\u062d\u062f\u064a\u062b \u062d\u0632\u0645 \u0627\u0644\u0646\u0638\u0627\u0645 (\u0642\u062f \u064a\u0633\u062a\u063a\u0631\u0642 \u0630\u0644\u0643 \u0639\u062f\u0629 \u062f\u0642\u0627\u0626\u0642)'
        'su_skipped' = '\u0644\u0646 \u064a\u062a\u0645 \u062a\u062d\u062f\u064a\u062b \u062d\u0632\u0645 \u0627\u0644\u0646\u0638\u0627\u0645 \u0623\u0648\u0644\u0627\u064b (TOUTWAF_SKIP_SYSUPDATE).'
        'su_recent' = '\u062a\u0645 \u062a\u062d\u062f\u064a\u062b \u062d\u0632\u0645 \u0627\u0644\u0646\u0638\u0627\u0645 \u0642\u0628\u0644 \u0623\u0642\u0644 \u0645\u0646 6 \u0633\u0627\u0639\u0627\u062a: \u0644\u0646 \u064a\u064f\u0643\u0631\u064e\u0651\u0631 \u0627\u0644\u062a\u062d\u062f\u064a\u062b.'
        'su_dry' = '\u0633\u064a\u062a\u0645 \u062a\u062d\u062f\u064a\u062b \u062d\u0632\u0645 \u0627\u0644\u0646\u0638\u0627\u0645 \u0623\u0648\u0644\u0627\u064b (\u0644\u062a\u062e\u0637\u064a \u0630\u0644\u0643: TOUTWAF_SKIP_SYSUPDATE=1)'
        'su_nopm' = '\u0644\u0627 \u064a\u0648\u062c\u062f \u0645\u062f\u064a\u0631 \u062d\u0632\u0645 \u0645\u062f\u0639\u0648\u0645 \u0644\u062a\u062d\u062f\u064a\u062b \u0627\u0644\u0646\u0638\u0627\u0645: \u062a\u0645 \u0627\u0644\u062a\u062e\u0637\u064a \u0648\u062a\u0633\u062a\u0645\u0631 \u0639\u0645\u0644\u064a\u0629 \u0627\u0644\u062a\u062b\u0628\u064a\u062a.'
        'su_failed' = '\u0641\u0634\u0644 \u062a\u062d\u062f\u064a\u062b \u062d\u0632\u0645 \u0627\u0644\u0646\u0638\u0627\u0645 (\u0627\u0644\u0631\u0645\u0632 {0})\u061b \u0633\u062a\u0633\u062a\u0645\u0631 \u0639\u0645\u0644\u064a\u0629 \u0627\u0644\u062a\u062b\u0628\u064a\u062a \u0628\u062f\u0648\u0646\u0647. \u0627\u0644\u062a\u0641\u0627\u0635\u064a\u0644: {1}. \u0627\u0644\u062d\u0644: \u0634\u063a\u0651\u0644 \u0627\u0644\u062a\u062d\u062f\u064a\u062b \u0628\u0646\u0641\u0633\u0643 \u0648\u0627\u0642\u0631\u0623 \u0631\u0633\u0627\u0644\u0629 \u0627\u0644\u062e\u0637\u0623 (\u0645\u0633\u062a\u0648\u062f\u0639 \u0645\u0639\u0637\u0651\u0644\u061f \u0645\u062f\u064a\u0631 \u062d\u0632\u0645 \u0622\u062e\u0631 \u0642\u064a\u062f \u0627\u0644\u062a\u0634\u063a\u064a\u0644\u061f) \u0623\u0648 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0647\u0630\u0627 \u0627\u0644\u0623\u0645\u0631 \u0645\u0639 TOUTWAF_SKIP_SYSUPDATE=1.'
        'su_reboot' = '\u064a\u0644\u0632\u0645 \u0625\u0639\u0627\u062f\u0629 \u062a\u0634\u063a\u064a\u0644 \u0647\u0630\u0627 \u0627\u0644\u062e\u0627\u062f\u0645 \u0644\u0625\u0643\u0645\u0627\u0644 \u062a\u062d\u062f\u064a\u062b \u0627\u0644\u0646\u0638\u0627\u0645 (\u0646\u0648\u0627\u0629 \u0623\u0648 \u0645\u0643\u062a\u0628\u0627\u062a \u062c\u062f\u064a\u062f\u0629). \u0644\u0627 \u064a\u0639\u064a\u062f ToutWAF \u062a\u0634\u063a\u064a\u0644\u0647 \u0646\u064a\u0627\u0628\u0629\u064b \u0639\u0646\u0643 \u0623\u0628\u062f\u0627\u064b: \u0627\u0641\u0639\u0644 \u0630\u0644\u0643 \u0639\u0646\u062f\u0645\u0627 \u062a\u0633\u062a\u0637\u064a\u0639.'
        'q_sysupdate' = '\u0647\u0644 \u062a\u0631\u064a\u062f \u062a\u062d\u062f\u064a\u062b \u062d\u0632\u0645 \u0627\u0644\u0646\u0638\u0627\u0645 \u0623\u0648\u0644\u0627\u064b (\u0645\u0648\u0635\u0649 \u0628\u0647)\u061f'
        'pr_disk_full' = '\u0627\u0644\u0645\u0633\u0627\u062d\u0629 \u0627\u0644\u062d\u0631\u0629 {0} \u0645\u064a\u063a\u0627\u0628\u0627\u064a\u062a \u0641\u0642\u0637 \u0639\u0644\u0649 {1} (\u0627\u0644\u0645\u0637\u0644\u0648\u0628 {2} \u0645\u064a\u063a\u0627\u0628\u0627\u064a\u062a \u0639\u0644\u0649 \u0627\u0644\u0623\u0642\u0644): \u0644\u0627 \u064a\u0645\u0643\u0646 \u0625\u0643\u0645\u0627\u0644 \u0627\u0644\u062a\u062b\u0628\u064a\u062a.'
        'pr_disk_full_a' = '\u062d\u0631\u0651\u0631 \u0628\u0639\u0636 \u0627\u0644\u0645\u0633\u0627\u062d\u0629 (\u0630\u0627\u0643\u0631\u0629 \u0627\u0644\u062d\u0632\u0645 \u0627\u0644\u0645\u0624\u0642\u062a\u0629: apt-get clean \u0623\u0648 dnf clean all\u061b \u0627\u0644\u0633\u062c\u0644\u0627\u062a \u0627\u0644\u0642\u062f\u064a\u0645\u0629: journalctl --vacuum-size=100M) \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0647\u0630\u0627 \u0627\u0644\u0623\u0645\u0631. \u0644\u0644\u0645\u062a\u0627\u0628\u0639\u0629 \u0631\u063a\u0645 \u0630\u0644\u0643: TOUTWAF_SKIP_PREREQ=1.'
        'pr_disk_full_w_a' = '\u062d\u0631\u0651\u0631 \u0628\u0639\u0636 \u0627\u0644\u0645\u0633\u0627\u062d\u0629 (\u062a\u0646\u0638\u064a\u0641 \u0627\u0644\u0642\u0631\u0635\u060c \u0625\u0641\u0631\u0627\u063a \u0633\u0644\u0629 \u0627\u0644\u0645\u062d\u0630\u0648\u0641\u0627\u062a) \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0647\u0630\u0627 \u0627\u0644\u0623\u0645\u0631. \u0644\u0644\u0645\u062a\u0627\u0628\u0639\u0629 \u0631\u063a\u0645 \u0630\u0644\u0643: $env:TOUTWAF_SKIP_PREREQ=1'
        'pr_disk_low' = '\u0627\u0644\u0645\u0633\u0627\u062d\u0629 \u0627\u0644\u062d\u0631\u0629 {0} \u0645\u064a\u063a\u0627\u0628\u0627\u064a\u062a \u0641\u0642\u0637 \u0639\u0644\u0649 {1} (\u064a\u064f\u0641\u0636\u064e\u0651\u0644 \u0646\u062d\u0648 {2} \u0645\u064a\u063a\u0627\u0628\u0627\u064a\u062a).'
        'pr_disk_low_a' = '\u062d\u0631\u0651\u0631 \u0628\u0639\u0636 \u0627\u0644\u0645\u0633\u0627\u062d\u0629 \u0623\u0648 \u0623\u0636\u0641 \u0642\u0631\u0635\u0627\u064b\u061b \u064a\u0645\u0643\u0646 \u0623\u0646 \u064a\u0633\u062a\u0645\u0631 \u0627\u0644\u062a\u062b\u0628\u064a\u062a.'
        'pr_dns' = '\u0644\u0627 \u064a\u0633\u062a\u0637\u064a\u0639 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u062d\u0644\u0651 \u0627\u0644\u0627\u0633\u0645 {0} (DNS).'
        'pr_dns_a' = '\u062a\u062d\u0642\u0642 \u0645\u0646 \u062e\u0648\u0627\u062f\u0645 DNS (cat /etc/resolv.conf\u060c resolvectl status) \u0648\u0623\u0636\u0641 \u062e\u0627\u062f\u0645\u0627\u064b \u064a\u0639\u0645\u0644 \u0645\u062b\u0644 nameserver 9.9.9.9 \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0647\u0630\u0627 \u0627\u0644\u0623\u0645\u0631.'
        'pr_dns_w_a' = '\u062a\u062d\u0642\u0642 \u0645\u0646 \u062e\u0648\u0627\u062f\u0645 DNS \u0628\u0627\u0633\u062a\u062e\u062f\u0627\u0645 ''ipconfig /all'' \u0648\u062d\u062f\u0651\u062f \u062e\u0627\u062f\u0645\u0627\u064b \u064a\u0639\u0645\u0644 (\u0645\u062b\u0644 9.9.9.9) \u0641\u064a \u0625\u0639\u062f\u0627\u062f\u0627\u062a \u0628\u0637\u0627\u0642\u0629 \u0627\u0644\u0634\u0628\u0643\u0629 \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0647\u0630\u0627 \u0627\u0644\u0623\u0645\u0631.'
        'pr_clock' = '\u0633\u0627\u0639\u0629 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u062a\u062e\u062a\u0644\u0641 \u0639\u0646 \u062a\u0648\u0642\u064a\u062a \u0627\u0644\u0625\u0646\u062a\u0631\u0646\u062a \u0628\u0645\u0642\u062f\u0627\u0631 {0} \u062b\u0627\u0646\u064a\u0629: \u062a\u0641\u0634\u0644 \u0634\u0647\u0627\u062f\u0627\u062a TLS \u0648\u0627\u0644\u062a\u0648\u0642\u064a\u0639\u0627\u062a \u0639\u0646\u062f\u0645\u0627 \u062a\u0643\u0648\u0646 \u0627\u0644\u0633\u0627\u0639\u0629 \u062e\u0627\u0637\u0626\u0629.'
        'pr_clock_a' = '\u0642\u0645 \u0628\u0645\u0632\u0627\u0645\u0646\u062a\u0647\u0627: timedatectl set-ntp true (\u0623\u0648 chronyc makestep) \u0648\u062a\u062d\u0642\u0642 \u0628\u0627\u0633\u062a\u062e\u062f\u0627\u0645 timedatectl \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0647\u0630\u0627 \u0627\u0644\u0623\u0645\u0631.'
        'pr_clock_w_a' = '\u0642\u0645 \u0628\u0645\u0632\u0627\u0645\u0646\u062a\u0647\u0627: w32tm /resync (\u0623\u0648 \u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a > \u0627\u0644\u0648\u0642\u062a \u0648\u0627\u0644\u0644\u063a\u0629 > \u0645\u0632\u0627\u0645\u0646\u0629 \u0627\u0644\u0622\u0646) \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0647\u0630\u0627 \u0627\u0644\u0623\u0645\u0631.'
        'pr_ok' = '\u0645\u0633\u0627\u062d\u0629 \u0627\u0644\u0642\u0631\u0635 \u0648DNS \u0648\u0627\u0644\u0633\u0627\u0639\u0629 \u0628\u062d\u0627\u0644\u0629 \u062c\u064a\u062f\u0629.'
        'cloud_https' = '\u064a\u062c\u0628 \u0623\u0646 \u064a\u0643\u0648\u0646 --cloud-url \u0639\u0646\u0648\u0627\u0646 https:// (\u0627\u0644\u0639\u0642\u062f\u0629 \u0644\u0627 \u062a\u062a\u062d\u062f\u062b \u0625\u0644\u0649 \u0627\u0644\u0633\u062d\u0627\u0628\u0629 \u062f\u0648\u0646 \u062a\u0634\u0641\u064a\u0631 \u0623\u0628\u062f\u064b\u0627).'
        'cloud_dp_only' = '--cloud-url \u064a\u062b\u0628\u0651\u062a \u0639\u0642\u062f\u0629 \u062d\u0645\u0627\u064a\u0629: \u0627\u0633\u062a\u062e\u062f\u0645\u0647 \u0645\u0639 --component dp (\u0627\u0644\u0627\u0641\u062a\u0631\u0627\u0636\u064a \u0641\u064a \u0648\u0636\u0639 \u0627\u0644\u0633\u062d\u0627\u0628\u0629).'
        'cloud_need_token' = '\u064a\u0644\u0632\u0645 \u0631\u0645\u0632 \u062a\u0633\u062c\u064a\u0644 \u0644\u0631\u0628\u0637 \u0647\u0630\u0647 \u0627\u0644\u0639\u0642\u062f\u0629 \u0628\u062d\u0633\u0627\u0628\u0643 (--enroll-token\u061b \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645: \u0627\u0644\u0639\u0642\u062f > \u0625\u0636\u0627\u0641\u0629 \u0623\u0648\u0644 \u0639\u0642\u062f\u0629).'
        'cloud_ca_local' = '\u064a\u062c\u0628 \u0623\u0646 \u064a\u0643\u0648\u0646 --cloud-ca \u0645\u0644\u0641\u064b\u0627 \u0645\u062d\u0644\u064a\u064b\u0627.'
        'cloud_nolink' = '\u0644\u0627 \u064a\u062a\u0636\u0645\u0646 \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631 \u0631\u0627\u0628\u0637 ToutWAF Cloud (toutwaf-cloudlink): \u062d\u062f\u0651\u062b \u0627\u0644\u0645\u062b\u0628\u0651\u062a \u0623\u0648 \u0627\u0633\u062a\u062e\u062f\u0645 \u0625\u0635\u062f\u0627\u0631\u064b\u0627 \u0623\u062d\u062f\u062b.'
        'cloud_enrol_failed' = '\u062a\u0639\u0630\u0651\u0631 \u062a\u0633\u062c\u064a\u0644 \u0627\u0644\u0639\u0642\u062f\u0629 \u0641\u064a \u062d\u0633\u0627\u0628\u0643 (\u0627\u0646\u0638\u0631 \u0627\u0644\u0623\u0633\u0637\u0631 \u0623\u0639\u0644\u0627\u0647). \u0631\u0628\u0645\u0627 \u0627\u0633\u062a\u064f\u062e\u062f\u0645 \u0627\u0644\u0631\u0645\u0632 \u0623\u0648 \u0627\u0646\u062a\u0647\u062a \u0635\u0644\u0627\u062d\u064a\u062a\u0647: \u0623\u0646\u0634\u0626 \u0631\u0645\u0632\u064b\u0627 \u062c\u062f\u064a\u062f\u064b\u0627 \u0641\u064a \u0644\u0648\u062d\u0629 \u0627\u0644\u062a\u062d\u0643\u0645.'
        'pf_cloud_action' = '\u0627\u0633\u0645\u062d \u0644\u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 \u0628\u0627\u0644\u0648\u0635\u0648\u0644 \u0625\u0644\u0649 \u0639\u0646\u0648\u0627\u0646 ToutWAF Cloud \u0627\u0644\u062e\u0627\u0635 \u0628\u0643 \u0639\u0628\u0631 \u0627\u0644\u0645\u0646\u0641\u0630 443 (\u0635\u0627\u062f\u0631 \u0641\u0642\u0637)\u060c \u0623\u0648 \u0639\u064a\u0651\u0646 HTTPS_PROXY \u0625\u0630\u0627 \u0644\u0632\u0645 \u0648\u0643\u064a\u0644. \u0644\u0627 \u062d\u0627\u062c\u0629 \u0644\u0641\u062a\u062d \u0623\u064a \u0634\u064a\u0621 \u0644\u0644\u0648\u0627\u0631\u062f.'
        's_db' = '\u062a\u062c\u0647\u064a\u0632 \u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a'
        'db_choose' = '\u0645\u0627 \u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0627\u0644\u062a\u064a \u0633\u064a\u0633\u062a\u062e\u062f\u0645\u0647\u0627 ToutWAF\u061f'
        'db_opt_pg' = 'PostgreSQL (\u0645\u0648\u0635\u0649 \u0628\u0647)'
        'db_opt_pg_local' = '\u062a\u062b\u0628\u064a\u062a PostgreSQL \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 (\u064a\u064f\u0646\u0634\u0623 \u0648\u064a\u064f\u0647\u064a\u0651\u0623 \u062a\u0644\u0642\u0627\u0626\u064a\u064b\u0627)'
        'db_opt_pg_remote' = '\u0627\u0633\u062a\u062e\u062f\u0627\u0645 \u062e\u0627\u062f\u0645 PostgreSQL \u0645\u0648\u062c\u0648\u062f (\u064a\u064f\u062e\u062a\u0628\u0631 \u062b\u0645 \u064a\u064f\u062c\u0647\u064e\u0651\u0632 \u0625\u0630\u0627 \u0633\u0645\u062d\u062a)'
        'db_opt_sqlite' = 'SQLite (\u062a\u062b\u0628\u064a\u062a \u0635\u063a\u064a\u0631\u060c \u062e\u0627\u062f\u0645 \u0648\u0627\u062d\u062f \u0641\u0642\u0637)'
        'db_sqlite_note' = 'SQLite \u0645\u0644\u0641 \u0648\u0627\u062d\u062f \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632: \u0645\u0646\u0627\u0633\u0628 \u0644\u062a\u062b\u0628\u064a\u062a \u0635\u063a\u064a\u0631 \u0639\u0644\u0649 \u062e\u0627\u062f\u0645 \u0648\u0627\u062d\u062f. \u0644\u0627 \u064a\u0645\u0643\u0646 \u0645\u0634\u0627\u0631\u0643\u062a\u0647 \u0628\u064a\u0646 \u0639\u062f\u0629 \u0648\u062d\u062f\u0627\u062a \u062a\u062d\u0643\u0645 \u0648\u0644\u0627 \u064a\u062f\u0639\u0645 \u0627\u0644\u0646\u0633\u062e \u0627\u0644\u0645\u062a\u0645\u0627\u062b\u0644. \u064a\u0645\u0643\u0646\u0643 \u0627\u0644\u0627\u0646\u062a\u0642\u0627\u0644 \u0625\u0644\u0649 PostgreSQL \u0644\u0627\u062d\u0642\u064b\u0627 \u0639\u0628\u0631: toutwaf-cp db migrate.'
        'db_q_host' = '\u0645\u0636\u064a\u0641 PostgreSQL'
        'db_q_port' = '\u0627\u0644\u0645\u0646\u0641\u0630'
        'db_q_name' = '\u0627\u0633\u0645 \u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a'
        'db_q_user' = '\u0645\u0633\u062a\u062e\u062f\u0645 \u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a'
        'db_q_pw' = '\u0643\u0644\u0645\u0629 \u0645\u0631\u0648\u0631 \u0647\u0630\u0627 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 (\u0627\u062a\u0631\u0643\u0647\u0627 \u0641\u0627\u0631\u063a\u0629 \u0625\u0630\u0627 \u0623\u0646\u0634\u0623\u0647 \u062d\u0633\u0627\u0628 \u0645\u0633\u0624\u0648\u0644)'
        'db_q_tls' = '\u0648\u0636\u0639 TLS (disable\u060c prefer\u060c require\u060c verify-ca\u060c verify-full)'
        'db_q_ca' = '\u0645\u0644\u0641 \u0634\u0647\u0627\u062f\u0629 CA \u0644\u0644\u062e\u0627\u062f\u0645 (\u0644\u0648\u0636\u0639\u064a verify-ca / verify-full)'
        'db_q_admin' = '\u062d\u0633\u0627\u0628 \u0627\u0644\u0645\u0633\u0624\u0648\u0644 \u0627\u0644\u0630\u064a \u064a\u0646\u0634\u0626 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 \u0648\u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a (\u0641\u0627\u0631\u063a = \u0645\u0648\u062c\u0648\u062f\u0627\u0646 \u0645\u0633\u0628\u0642\u064b\u0627)'
        'db_q_adminpw' = '\u0643\u0644\u0645\u0629 \u0645\u0631\u0648\u0631 \u062d\u0633\u0627\u0628 \u0627\u0644\u0645\u0633\u0624\u0648\u0644 (\u062a\u064f\u0633\u062a\u062e\u062f\u0645 \u0645\u0631\u0629 \u0648\u0627\u062d\u062f\u0629 \u0648\u0644\u0627 \u062a\u064f\u062d\u0641\u0638)'
        'db_hint' = '\u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a: SQLite (\u0627\u0641\u062a\u0631\u0627\u0636\u064a). \u0644\u0644\u062a\u062b\u0628\u064a\u062a \u0639\u0644\u0649 \u062e\u0627\u062f\u0645 \u0623\u0648 \u0644\u0639\u062f\u0629 \u0648\u062d\u062f\u0627\u062a \u062a\u062d\u0643\u0645 \u0627\u0633\u062a\u062e\u062f\u0645 --db postgres (\u0648--db-install-local \u064a\u062b\u0628\u0651\u062a\u0647\u0627 \u0644\u0643).'
        'db_no_pkg' = '\u062a\u0639\u0630\u0651\u0631 \u062a\u062b\u0628\u064a\u062a PostgreSQL \u062a\u0644\u0642\u0627\u0626\u064a\u064b\u0627 \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u0646\u0638\u0627\u0645: \u062b\u0628\u0651\u062a \u062d\u0632\u0645\u0629 \u0627\u0644\u062e\u0627\u062f\u0645 \u0628\u0646\u0641\u0633\u0643 \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u062b\u0628\u0651\u062a \u0645\u0639 --db postgres.'
        'db_install_failed' = '\u0641\u0634\u0644 \u062a\u062b\u0628\u064a\u062a \u062d\u0632\u0645\u0629 PostgreSQL. \u0627\u0644\u0633\u0628\u0628 \u0641\u064a \u0627\u0644\u0633\u062c\u0644 (/var/log/toutwaf-install.log).'
        'db_init_failed' = '\u062a\u0639\u0630\u0651\u0631\u062a \u062a\u0647\u064a\u0626\u0629 \u0645\u062c\u0645\u0648\u0639\u0629 PostgreSQL. \u0627\u0644\u0633\u0628\u0628 \u0641\u064a \u0627\u0644\u0633\u062c\u0644.'
        'db_start_failed' = '\u0644\u0627 \u064a\u0628\u062f\u0623 PostgreSQL. \u0627\u0641\u062d\u0635: systemctl status postgresql \u0648\u0627\u0644\u0633\u062c\u0644.'
        'db_too_old' = '\u0625\u0635\u062f\u0627\u0631 PostgreSQL \u0627\u0644\u0645\u062b\u0628\u0651\u062a \u0647\u0646\u0627 ({0}) \u0642\u062f\u064a\u0645 \u062c\u062f\u064b\u0627: \u064a\u0644\u0632\u0645 \u0627\u0644\u0625\u0635\u062f\u0627\u0631 13 \u0623\u0648 \u0623\u062d\u062f\u062b.'
        'db_exists' = '\u064a\u0648\u062c\u062f \u0645\u0633\u062a\u062e\u062f\u0645 "{0}" \u0623\u0648 \u0642\u0627\u0639\u062f\u0629 "{1}" \u0644\u0645 \u064a\u0646\u0634\u0626\u0647\u0627 \u0647\u0630\u0627 \u0627\u0644\u0645\u062b\u0628\u0651\u062a: \u0644\u0645 \u064a\u064f\u063a\u064a\u064e\u0651\u0631 \u0634\u064a\u0621. \u0627\u062e\u062a\u0631 \u0623\u0633\u0645\u0627\u0621 \u0623\u062e\u0631\u0649 (--db-name \u0648--db-user) \u0623\u0648 \u0642\u062f\u0651\u0645 \u0627\u0644\u0627\u062a\u0635\u0627\u0644 \u0627\u0644\u0645\u0648\u062c\u0648\u062f (--db-dsn-file).'
        'db_create_failed' = '\u062a\u0639\u0630\u0651\u0631 \u0625\u0646\u0634\u0627\u0621 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 \u0623\u0648 \u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a. \u0623\u064f\u0632\u064a\u0644 \u0645\u0627 \u0623\u064f\u0646\u0634\u0626.'
        'db_rights' = '\u0644\u064a\u0633 \u0644\u0647\u0630\u0627 \u0627\u0644\u062d\u0633\u0627\u0628 \u0635\u0644\u0627\u062d\u064a\u0629. \u0627\u0644\u062a\u0639\u0644\u064a\u0645\u0627\u062a \u0623\u0639\u0644\u0627\u0647 \u0647\u064a \u0627\u0644\u062d\u062f \u0627\u0644\u0623\u062f\u0646\u0649 \u0627\u0644\u0630\u064a \u064a\u062c\u0628 \u0623\u0646 \u064a\u0646\u0641\u0630\u0647 \u0645\u0633\u0624\u0648\u0644 \u0627\u0644\u062e\u0627\u062f\u0645\u061b \u062b\u0645 \u0623\u0639\u062f \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0645\u062b\u0628\u0651\u062a.'
        'db_need_conn' = '\u0644\u0645 \u062a\u064f\u062d\u062f\u064e\u0651\u062f \u0623\u064a \u0645\u0639\u0644\u0648\u0645\u0627\u062a \u0627\u062a\u0635\u0627\u0644 \u0628\u062e\u0627\u062f\u0645 PostgreSQL: \u0627\u0633\u062a\u062e\u062f\u0645 --db-dsn-file \u0623\u0648 --db-host \u0645\u0639 --db-password-file \u0623\u0648 --db-install-local.'
        'db_schema_failed' = '\u062a\u0639\u0630\u0651\u0631 \u0625\u0646\u0634\u0627\u0621 \u0627\u0644\u062c\u062f\u0627\u0648\u0644 \u0641\u064a \u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a. \u0627\u0644\u0633\u0628\u0628 \u0641\u064a \u0627\u0644\u0633\u062c\u0644.'
        'db_no_pgdump' = 'pg_dump \u063a\u064a\u0631 \u0645\u0648\u062c\u0648\u062f: \u0633\u062a\u064f\u0628\u0644\u063a \u0627\u0644\u0646\u0633\u062e\u0629 \u0627\u0644\u064a\u0648\u0645\u064a\u0629 \u0644\u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0639\u0646 \u062e\u0637\u0623 \u062d\u062a\u0649 \u062a\u064f\u062b\u0628\u064e\u0651\u062a \u062d\u0632\u0645\u0629 \u0639\u0645\u064a\u0644 PostgreSQL.'
        'db_sum_engine' = '\u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a: {0}'
        'db_sum_local' = '\u064a\u0639\u0645\u0644 PostgreSQL \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 (\u0627\u0644\u0648\u0627\u062c\u0647\u0629 \u0627\u0644\u0645\u062d\u0644\u064a\u0629 \u0641\u0642\u0637)\u061b \u0627\u0644\u0642\u0627\u0639\u062f\u0629 {0} \u0648\u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 {1} (\u0628\u0644\u0627 \u0635\u0644\u0627\u062d\u064a\u0627\u062a \u0625\u062f\u0627\u0631\u064a\u0629)'
        'db_sum_remote' = '\u062e\u0627\u062f\u0645 PostgreSQL \u0645\u0648\u062c\u0648\u062f\u061b \u0627\u0644\u0642\u0627\u0639\u062f\u0629 {0} \u0648\u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 {1}'
        'db_sum_schema' = '\u0627\u0644\u0645\u062e\u0637\u0637: {0}'
        'db_sum_secret' = '\u0627\u0644\u0627\u062a\u0635\u0627\u0644 (\u0645\u0639 \u0643\u0644\u0645\u0629 \u0627\u0644\u0645\u0631\u0648\u0631) \u0641\u064a {0} \u0648\u0644\u0627 \u064a\u0642\u0631\u0624\u0647 \u0625\u0644\u0627 \u062e\u062f\u0645\u0629 ToutWAF'
        'db_sum_backup' = '\u064a\u0639\u0645\u0644 pg_dump \u0645\u0648\u062b\u064e\u0651\u0642 \u0643\u0644 \u0644\u064a\u0644\u0629 (\u064a\u064f\u062d\u062a\u0641\u0638 \u0628\u0640 7)\u061b \u0627\u0644\u062d\u0627\u0644\u0629 \u0641\u064a \u0648\u062d\u062f\u0629 \u0627\u0644\u062a\u062d\u0643\u0645\u060c Sant\u00e9'
        'db_sum_nobackup' = '\u0644\u0627 \u062a\u0648\u062c\u062f \u0646\u0633\u062e\u0629 \u0627\u062d\u062a\u064a\u0627\u0637\u064a\u0629 \u062a\u0644\u0642\u0627\u0626\u064a\u0629 \u0644\u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a: \u062c\u062f\u0648\u0644 pg_dump \u0623\u0648 \u0627\u0633\u062a\u062e\u062f\u0645 \u0646\u0633\u062e \u0645\u0632\u0648\u0651\u062f \u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a'
        'db_sum_sqlite' = '\u0642\u0627\u0639\u062f\u0629 \u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a: SQLite\u060c \u0645\u0644\u0641 \u0648\u0627\u062d\u062f \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632 (\u062a\u062b\u0628\u064a\u062a \u0635\u063a\u064a\u0631). \u0627\u0644\u0627\u0646\u062a\u0642\u0627\u0644 \u0625\u0644\u0649 PostgreSQL \u0644\u0627\u062d\u0642\u064b\u0627: toutwaf-cp db migrate'
        's_extras' = '\u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a: \u0648\u0643\u064a\u0644 Windows \u0648\u0628\u0631\u0627\u0645\u062c \u0645\u0643\u0627\u0641\u062d\u0629 \u0627\u0644\u0641\u064a\u0631\u0648\u0633\u0627\u062a'
        's_extras_ok' = '\u062a\u0645 \u062a\u062b\u0628\u064a\u062a \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a: {0} \u0628\u0631\u0646\u0627\u0645\u062c \u0641\u064a {1}'
        's_extras_sha' = '\u062a\u0645 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a: {0} \u0645\u0644\u0641\u060c {1} \u0645\u064a\u0628\u064a\u0628\u0627\u064a\u062a (SHA-256 \u0648\u0627\u0644\u062a\u0648\u0642\u064a\u0639)'
        's_extras_unchecked' = '\u062a\u0645 \u0623\u062e\u0630 \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a \u0643\u0645\u0627 \u0647\u064a \u062f\u0648\u0646 SHA256SUMS \u0644\u0644\u062a\u062d\u0642\u0642 \u0645\u0646\u0647\u0627: {0}'
        'w_extras_dl' = '\u062a\u0639\u0630\u0631 \u062a\u0646\u0632\u064a\u0644 \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a ({0}). \u064a\u0639\u0645\u0644 ToutWAF \u0628\u062f\u0648\u0646\u0647\u0627\u060c \u0644\u0643\u0646 \u0647\u0630\u0647 \u0627\u0644\u0644\u0648\u062d\u0629 \u0644\u0646 \u062a\u0639\u0631\u0636 Windows \u0648\u0644\u0627 \u0645\u0643\u0627\u0641\u062d\u0629 \u0627\u0644\u0641\u064a\u0631\u0648\u0633\u0627\u062a \u062d\u062a\u0649 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a\u0647\u0627.'
        'w_extras_sum' = '\u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a {0} \u0644\u0627 \u062a\u0637\u0627\u0628\u0642 \u0642\u064a\u0645\u0629 SHA-256 \u0641\u064a SHA256SUMS \u0627\u0644\u0645\u0648\u0642\u0651\u0639: \u0644\u0645 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a\u0647\u0627.'
        'w_extras_bad' = '\u0645\u0644\u0641 \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a {0} \u0644\u064a\u0633 \u0623\u0631\u0634\u064a\u0641 \u0625\u0636\u0627\u0641\u0627\u062a \u0635\u0627\u0644\u062d\u0627: \u0644\u0645 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a\u0647.'
        'w_extras_ver' = '\u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a \u062e\u0627\u0635\u0629 \u0628\u0627\u0644\u0625\u0635\u062f\u0627\u0631 {0} \u0648\u0647\u0630\u0627 \u0627\u0644\u062a\u062b\u0628\u064a\u062a \u0647\u0648 {1}: \u0644\u0645 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a\u0647\u0627.'
        'w_extras_inc' = '\u064a\u0633\u0631\u062f \u0627\u0644\u0625\u0635\u062f\u0627\u0631 {0} \u062c\u0632\u0621\u0627 \u0645\u0646 \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a \u0644\u0643\u0646\u0647 \u064a\u0630\u0643\u0631 {1}: \u0627\u0644\u0646\u0634\u0631 \u062a\u0627\u0644\u0641 \u0648\u0644\u0645 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a.'
        'w_extras_nofile' = '\u0645\u0644\u0641 \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a {0} \u063a\u064a\u0631 \u0645\u0648\u062c\u0648\u062f.'
        'w_extras_none' = '\u0644\u0627 \u064a\u062d\u062a\u0648\u064a \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631 \u0639\u0644\u0649 \u0625\u0636\u0627\u0641\u0627\u062a: \u0644\u0646 \u062a\u0639\u0631\u0636 \u0647\u0630\u0647 \u0627\u0644\u0644\u0648\u062d\u0629 Windows \u0648\u0644\u0627 \u0645\u0643\u0627\u0641\u062d\u0629 \u0627\u0644\u0641\u064a\u0631\u0648\u0633\u0627\u062a.'
        'w_extras_todo' = '\u0644\u0645 \u064a\u062a\u0645 \u062a\u062b\u0628\u064a\u062a \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a. \u0639\u0646\u062f\u0645\u0627 \u062a\u0633\u0645\u062d \u0627\u0644\u0634\u0628\u0643\u0629\u060c \u0634\u063a\u0651\u0644 \u0628\u0635\u0644\u0627\u062d\u064a\u0627\u062a root: {0}'
        'extras_needs_cp' = '\u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a \u062a\u062e\u0635 \u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u062a\u062d\u0643\u0645: \u0648\u0647\u0648 \u063a\u064a\u0631 \u0645\u062b\u0628\u062a \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632.'
        'extras_other_release' = '\u0627\u0644\u0625\u0635\u062f\u0627\u0631 \u0627\u0644\u0645\u0646\u0634\u0648\u0631 ({0}) \u0644\u064a\u0633 \u0627\u0644\u0645\u062b\u0628\u062a ({1}): \u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a \u062a\u0623\u062a\u064a \u0645\u0639\u0647. \u0634\u063a\u0651\u0644 --update.'
        'st_extras_ok' = '\u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a: \u0645\u062b\u0628\u062a\u0629 (\u0648\u0643\u064a\u0644 Windows \u0648\u0628\u0631\u0627\u0645\u062c \u0645\u0643\u0627\u0641\u062d\u0629 \u0627\u0644\u0641\u064a\u0631\u0648\u0633\u0627\u062a)'
        'st_extras_none' = '\u0627\u0644\u0625\u0636\u0627\u0641\u0627\u062a \u0645\u0641\u0642\u0648\u062f\u0629: \u0644\u0627 \u064a\u062a\u0645 \u0639\u0631\u0636 Windows \u0648\u0644\u0627 \u0645\u0643\u0627\u0641\u062d\u0629 \u0627\u0644\u0641\u064a\u0631\u0648\u0633\u0627\u062a. \u0634\u063a\u0651\u0644 \u0628\u0635\u0644\u0627\u062d\u064a\u0627\u062a root: {0}'
    }
}
# END CATALOG

function T([string]$Key, [object[]]$A = @()) {
    $s = $null
    $c = $script:Catalog[$script:UiLang]
    if ($c -and $c.ContainsKey($Key)) { $s = $c[$Key] }
    elseif ($script:Catalog['en'].ContainsKey($Key)) { $s = $script:Catalog['en'][$Key] }
    else { return $Key }
    $s = [regex]::Unescape($s)
    if ($A.Count -gt 0) { return ($s -f $A) }
    return $s
}

# ------------------------------------------------------------------------------------------------ UI
$script:Esc = [string][char]27
$script:UiLang = 'en'
$script:Color = $false
$script:Utf = $false
$script:TrueColor = $false
$script:LogReady = $false
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:BannerDone = $false
$script:Spinner = $null
$script:Bs = $null
$script:DbBackup = ''
$script:PanelTried = $false
$script:Rel = $null
$script:ResolvedVersion = ''
foreach ($n in 'R', 'B', 'D', 'Red', 'Grn', 'Ylw', 'Acc', 'Vio') { Set-Variable -Name $n -Scope Script -Value '' }

function Enable-Vt {
    # ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x4) on the output console (Windows 10+); already on in Windows Terminal / pwsh on Linux
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { return $true }
    try {
        if (-not ('Tw.Vt' -as [type])) {
            Add-Type -Namespace 'Tw' -Name 'Vt' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int h);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out int m);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, int m);
'@ -ErrorAction Stop
        }
        $h = [Tw.Vt]::GetStdHandle(-11)
        $mode = 0
        if (-not [Tw.Vt]::GetConsoleMode($h, [ref]$mode)) { return $false }
        if (($mode -band 4) -ne 0) { return $true }
        return [Tw.Vt]::SetConsoleMode($h, ($mode -bor 4))
    } catch { return $false }
}

function Initialize-Ui {
    # order: -Fr / -Lang fr, then $env:TOUTWAF_LANG, then the Windows display language, then English
    $l = $Lang
    foreach ($code in 'en', 'fr', 'es', 'de', 'it', 'pt', 'nl', 'ru', 'zh', 'ar') {
        if ((Get-Variable -Name $code -ValueOnly -ErrorAction SilentlyContinue) -eq $true) { $l = $code }
    }
    if (-not $l) { $l = $env:TOUTWAF_LANG }
    if (-not $l) { try { $l = (Get-UICulture).TwoLetterISOLanguageName } catch { $l = 'en' } }
    $l = "$l".ToLower()
    if ($l.Length -gt 2) { $l = $l.Substring(0, 2) }
    if (@('en', 'fr', 'es', 'de', 'it', 'pt', 'nl', 'ru', 'zh', 'ar') -notcontains $l) { $l = 'en' }
    $script:UiLang = $l
    # colour needs an interactive console with VT sequences; NO_COLOR / -NoColor / redirected output turn it off
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
    $vt = $false
    if (-not $redirected -and -not $NoColor -and -not $env:NO_COLOR -and $env:TERM -ne 'dumb') { $vt = Enable-Vt }
    $script:Color = $vt
    $script:TrueColor = ($env:COLORTERM -eq 'truecolor' -or $env:COLORTERM -eq '24bit' -or [bool]$env:WT_SESSION)
    # Unicode glyphs only where the host renders them (Windows Terminal, PowerShell 7, VS Code, ConEmu)
    $modern = ($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:ConEmuANSI -eq 'ON' -or $PSVersionTable.PSVersion.Major -ge 7)
    if (-not $redirected -and $modern) {
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); $script:Utf = $true } catch { $script:Utf = $false }
    } elseif ($redirected -and $PSVersionTable.PSVersion.Major -ge 7) { $script:Utf = $true }
    if (-not $script:Utf -and $script:UiLang -ne 'en') { $script:UiLang = 'en' }   # accents / non-Latin scripts need a UTF-8 console
    if ($script:Color) {
        $script:R = "$($script:Esc)[0m"; $script:B = "$($script:Esc)[1m"; $script:D = "$($script:Esc)[2m"
        $script:Red = "$($script:Esc)[31m"; $script:Grn = "$($script:Esc)[32m"; $script:Ylw = "$($script:Esc)[33m"
        $script:Acc = "$($script:Esc)[38;5;75m"; $script:Vio = "$($script:Esc)[38;5;141m"
    }
    if ($script:Utf) {
        $script:OkM = [string][char]0x2714; $script:ErM = [string][char]0x2716; $script:WrM = '!'; $script:Bul = [string][char]0x2022
        $script:Hr = [string][char]0x2500; $script:Vr = [string][char]0x2502; $script:Tl = [string][char]0x256D; $script:Bl = [string][char]0x2570; $script:Arw = [string][char]0x203A
        $script:Frames = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F) | ForEach-Object { [string][char]$_ }
    } else {
        $script:OkM = '[ok]'; $script:ErM = '[x]'; $script:WrM = '[!]'; $script:Bul = '*'
        $script:Hr = '-'; $script:Vr = '|'; $script:Tl = '+'; $script:Bl = '+'; $script:Arw = '>'
        $script:Frames = @('|', '/', '-', '\')
    }
}

# Zero telemetry was asked for: -NoTelemetry or $env:TOUTWAF_TELEMETRY = 0 / false / off / no / none / zero.
function Test-NoTelemetry { return ($NoTelemetry -or ($env:TOUTWAF_TELEMETRY -and $env:TOUTWAF_TELEMETRY.ToLower() -in @('0', 'false', 'off', 'no', 'none', 'zero'))) }
function Write-Out([string]$s) { if (-not $Quiet) { Write-Host $s } }
function Paint([string]$c, [string]$s) { return "$c$s$($script:R)" }
function Rule([int]$n) { return ($script:Hr * $n) }

function Get-BannerRows {
    # tokens keep this file ASCII: # full block, 1 double top-right, 2 double top-left, 3 double bottom-right, 4 double bottom-left, 5 double vertical, 6 double horizontal
    return @(
        '########1 ######1 ##1   ##1########1##1    ##1 #####1 #######1',
        '466##2663##2666##1##5   ##5466##2663##5    ##5##266##1##266663',
        '   ##5   ##5   ##5##5   ##5   ##5   ##5 #1 ##5#######5#####1',
        '   ##5   ##5   ##5##5   ##5   ##5   ##5###1##5##266##5##2663',
        '   ##5   4######234######23   ##5   4###2###23##5  ##5##5',
        '   463    4666663  4666663    463    46634663 463  463463'
    )
}
function ConvertTo-BannerGlyphs([string]$row) {
    $m = @{ '#' = 0x2588; '1' = 0x2557; '2' = 0x2554; '3' = 0x255D; '4' = 0x255A; '5' = 0x2551; '6' = 0x2550 }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $row.ToCharArray()) { if ($m.ContainsKey([string]$ch)) { [void]$sb.Append([char]$m[[string]$ch]) } else { [void]$sb.Append($ch) } }
    return $sb.ToString()
}

function Write-Banner {
    if ($Quiet -or $script:BannerDone) { return }
    $script:BannerDone = $true
    Write-Host ''
    if ($script:Utf) {
        $rows = @(Get-BannerRows | ForEach-Object { ConvertTo-BannerGlyphs $_ })
    } else {
        $rows = @(
            ' _____ ___  _   _ _____ __        ___    _____ ',
            '|_   _/ _ \| | | |_   _|\ \      / / \  |  ___|',
            '  | || | | | | | | | |   \ \ /\ / / _ \ | |_   ',
            '  | || |_| | |_| | | |    \ V  V / ___ \|  _|  ',
            '  |_| \___/ \___/  |_|     \_/\_/_/   \_\_|    ')
    }
    $pal = @(27, 33, 69, 105, 141, 135)
    foreach ($row in $rows) {
        if ($script:Color) {
            $w = $row.Length
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('  ')
            for ($i = 0; $i -lt $w; $i++) {
                $ch = $row[$i]
                if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
                if ($script:TrueColor) {   # blue (59,130,246) -> violet (139,92,246)
                    $r = [int](59 + (139 - 59) * $i / $w); $g = [int](130 + (92 - 130) * $i / $w)
                    [void]$sb.Append("$($script:Esc)[38;2;$r;$g;246m")
                } else { [void]$sb.Append("$($script:Esc)[38;5;$($pal[[int][math]::Floor($i * 6 / $w)])m") }
                [void]$sb.Append($ch)
            }
            Write-Host ($sb.ToString() + $script:R)
        } else { Write-Host "  $row" }
    }
    Write-Host ("  {0}{1}{2}  {3}.{2}  {3}installer v{4}{2}" -f $script:B, (T 'tagline'), $script:R, $script:D, $script:InstallerVersion)
    Write-Host ''
}

function FrameFill([string]$t) { return [Math]::Max(3, 74 - $t.Length) }
function Box-Top([string]$title) { if (-not $Quiet) { Write-Host ("{0}{1}{2} {3}{4}{5}{0} {6}{5}" -f $script:Acc, $script:Tl, $script:Hr, $script:B, $title, $script:R, (Rule (FrameFill $title))) } }
function Box-Line([string]$s) { if (-not $Quiet) { Write-Host ("{0}{1}{2} {3}" -f $script:Acc, $script:Vr, $script:R, $s) } }
function Box-Bottom { if (-not $Quiet) { Write-Host ("{0}{1}{2}{3}" -f $script:Acc, $script:Bl, (Rule 77), $script:R) } }

function Write-InstallLog([string]$m) {
    if ($script:LogReady) { try { Add-Content -Path $LogFile -Value $m -Encoding UTF8 } catch { $null = $_ } }
}
function Write-Info([string]$m) {
    Write-InstallLog $m
    if (-not $script:Color -and -not $Quiet) { Write-Host ("    {0} {1}" -f $script:Bul, $m) }
}
function Write-Warn([string]$m) {
    $script:Warnings.Add($m)
    Write-InstallLog "[warn] $m"
    if (-not $script:Color -and -not $Quiet) { Write-Host "[warn] $m" -ForegroundColor Yellow }
}

# the spinner runs on its own thread (C#): the PowerShell host cannot run script callbacks from a timer thread
function Start-Spin([string]$msg) {
    if ($Quiet -or -not $script:Color) { if (-not $Quiet) { Write-Host ("  {0} {1}" -f $script:Bul, $msg) }; return }
    try {
        if (-not ('TwSpinner' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Threading;
public class TwSpinner {
  Thread t; volatile bool run; string msg; string[] frames; string pre; string post;
  public void Start(string m, string[] f, string pre, string post) { msg = m; frames = f; this.pre = pre; this.post = post; run = true; t = new Thread(Loop); t.IsBackground = true; t.Start(); }
  void Loop() { int i = 0; while (run) { Console.Write("\r  " + pre + frames[i % frames.Length] + post + " " + msg + "\u001b[K"); i++; Thread.Sleep(100); } }
  public void Stop() { run = false; if (t != null) t.Join(); Console.Write("\r\u001b[K"); }
}
'@ -ErrorAction Stop
        }
        $script:Spinner = New-Object TwSpinner
        [Console]::Write("$($script:Esc)[?25l")
        $script:Spinner.Start($msg, [string[]]$script:Frames, $script:Acc, $script:R)
    } catch { $script:Spinner = $null; Write-Host ("  {0} {1}" -f $script:Bul, $msg) }
}
function Stop-Spin {
    if ($script:Spinner) { $script:Spinner.Stop(); $script:Spinner = $null; [Console]::Write("$($script:Esc)[?25h") }
}
function Invoke-Step([string]$msg, [scriptblock]$body) {
    if ($DryRun) { Write-Host ("  {0} {1}" -f $script:Bul, $msg); & $body; return }
    Write-InstallLog "== $msg"
    Start-Spin $msg
    try { & $body }
    catch {
        Stop-Spin
        Write-Host ("{0}{1} {2}: {3}{4}" -f $script:Red, $script:ErM, $msg, $_.Exception.Message, $script:R)
        Write-InstallLog ('FAILED: ' + $_.Exception.Message)
        Write-Host ('    ' + (T 'log_hint' @($LogFile)))
        throw
    }
    Stop-Spin
    if ($script:Color -and -not $Quiet) { Write-Host ("  {0}{1}{2} {3}" -f $script:Grn, $script:OkM, $script:R, $msg) }
}

function Test-Interactive {
    if ($Yes -or $AcceptDefaults) { return $false }
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { return $false }
}
function Read-Answer([string]$label, [string]$def = '', [switch]$Secret) {
    $suffix = if ($def) { " [$def]" } else { '' }
    Write-Host ("  {0}{1}{2} {3}{4}{5}{2} " -f $script:Acc, $script:Arw, $script:R, $label, $script:D, $suffix) -NoNewline
    if ($Secret) {
        $ss = Read-Host -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { $a = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } else { $a = Read-Host }
    if ([string]::IsNullOrEmpty($a)) { return $def }
    return $a
}
function Read-YesNo([string]$label, [bool]$def) {
    $hint = if ($def) { 'Y/n' } else { 'y/N' }
    while ($true) {
        Write-Host ("  {0}{1}{2} {3} {4}[{5}]{2} " -f $script:Acc, $script:Arw, $script:R, $label, $script:D, $hint) -NoNewline
        $a = (Read-Host).Trim().ToLower()
        if ($a -eq '') { return $def }
        if ($a -match '^(y|o|j|s|d|1)' -or $a.StartsWith([string][char]0x662F) -or $a.StartsWith([string][char]0x0434)) { return $true }
        if ($a -match '^(n|0)' -or $a.StartsWith([string][char]0x5426) -or $a.StartsWith([string][char]0x043D)) { return $false }
    }
}

# ------------------------------------------------------------------------------------------------ helpers
function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# machine architecture: [RuntimeInformation]::OSArchitecture first ($env:PROCESSOR_ARCHITECTURE says AMD64 inside an x64 PowerShell emulated on Windows on ARM)
function Get-MachineArch {
    $raw = $null
    try { $raw = ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture).ToString() } catch { $raw = $null }
    if (-not $raw) { $raw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { [string]$env:PROCESSOR_ARCHITECTURE } }
    return $raw
}
function Get-Arch {
    switch (Get-MachineArch) {
        { $_ -in @('X64', 'AMD64') } { return 'amd64' }
        { $_ -in @('Arm64', 'ARM64') } { return 'arm64' }
        default { throw "Unsupported architecture: $(Get-MachineArch)" }
    }
}
function Get-WindowsCompat {
    $build = 0; $kind = 'client'; $arch = Get-MachineArch; $caption = ''
    $hook = [string]$env:TOUTWAF_TEST_WINVER
    if ($hook -and ($DryRun -or $CheckCompat)) {
        $h = $hook -split '\|'
        $build = [int]$h[0]; if ($h.Count -gt 1) { $kind = $h[1] }; if ($h.Count -gt 2) { $arch = $h[2] }; if ($h.Count -gt 3) { $caption = $h[3] }
    } else {
        $isWin = $true
        try { $isWin = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) } catch { $isWin = $true }
        if ($isWin) {
            try {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $build = [int]$os.BuildNumber; $caption = [string]$os.Caption
                if ([int]$os.ProductType -ne 1) { $kind = 'server' }
            } catch { $build = [Environment]::OSVersion.Version.Build }
        }
    }
    $reasons = New-Object System.Collections.Generic.List[string]
    $name = ''; $status = 'expected'
    $min = if ($kind -eq 'server') { $script:WinMinServer } else { $script:WinMinClient }
    $match = $null
    foreach ($e in $script:WinEditions) { if ($e.Kind -eq $kind -and $build -ge $e.Build -and (-not $match -or $e.Build -gt $match.Build)) { $match = $e } }
    if ($build -le 0) { $reasons.Add((T 'cp_r_unknown' @('windows', ''))) }
    elseif (-not $match) {
        $minName = (@($script:WinEditions | Where-Object { $_.Kind -eq $kind -and $_.Build -eq $min }) | Select-Object -First 1).Name
        $reasons.Add((T 'cp_r_old' @($(if ($kind -eq 'server') { 'Windows Server' } else { 'Windows' }), "build $build", "$minName, build $min")))
    } else { $name = $match.Name; $status = $match.Status }
    $archId = switch ($arch) { { $_ -in @('X64', 'AMD64') } { 'amd64' } { $_ -in @('Arm64', 'ARM64') } { 'arm64' } default { $arch } }
    if ($script:WinArchOk -notcontains $archId) { $reasons.Add((T 'cp_r_arch' @($archId, ($script:WinArchOk -join ' ')))) }
    if ($reasons.Count -gt 0) { $status = 'unsupported' }
    $label = if ($name) { $name } elseif ($caption) { $caption } else { 'Windows' }
    return @{ Label = $label; Build = $build; Arch = $archId; Status = $status; Reasons = @($reasons) }
}
function Write-WindowsCompat($c) {
    Write-Host ''
    Write-Host ('  ' + (T 'cp_title'))
    Write-Host ('  ' + (T 'cp_wdetected' @($c.Label, $c.Build, $c.Arch)))
    if ($c.Status -eq 'unsupported') {
        Write-Host ('  ' + (T 'cp_refused'))
        foreach ($r in $c.Reasons) { Write-Host ("    - $r") }
    } else {
        Write-Host ('  ' + (T 'cp_ok' @($c.Label, (T "cp_$($c.Status)"))))
    }
    Write-Host ''
    Write-Host ('  ' + (T 'cp_wlist'))
    foreach ($e in $script:WinEditions) { Write-Host ('    {0,-44} build >= {1,-6} {2}' -f $e.Name, $e.Build, (T "cp_$($e.Status)")) }
    Write-Host ''
}
$script:CompatLine = ''
function Stop-ServiceSafe([string]$name) {
    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Stopped') {
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        try { $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(40)) } catch { Write-InstallLog "service $name did not stop in 40 s" }
    }
}
function Test-Port([int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null); return ($iar.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) } catch { return $false } finally { $c.Close() }
}
function Get-HttpStatus([string]$url) {
    # plain GET that tolerates the control plane's self-signed certificate (local probe only); 0 = no answer
    try {
        $u = [Uri]$url
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($u.Host, $u.Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(2000)) { $tcp.Close(); return 0 }
        $tcp.EndConnect($iar)
        $tcp.ReceiveTimeout = 3000; $tcp.SendTimeout = 3000
        $stream = $tcp.GetStream()
        if ($u.Scheme -eq 'https') {
            $cb = [System.Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) $true }
            $ssl = New-Object System.Net.Security.SslStream($stream, $false, $cb)
            $ssl.AuthenticateAsClient($u.Host); $stream = $ssl
        }
        $req = [Text.Encoding]::ASCII.GetBytes("GET $($u.PathAndQuery) HTTP/1.0`r`nHost: $($u.Host)`r`n`r`n")
        $stream.Write($req, 0, $req.Length); $stream.Flush()
        $buf = New-Object byte[] 64
        $n = $stream.Read($buf, 0, 64)
        $tcp.Close()
        $line = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
        if ($line -match 'HTTP/\d\.\d (\d{3})') { return [int]$Matches[1] }
        return 0
    } catch { return 0 }
}
function Test-DpHealthy {
    try { $r = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:9101/healthz' -TimeoutSec 2; return ($r.StatusCode -eq 200) } catch { return $false }
}
function Wait-DpHealthy { for ($i = 0; $i -lt 30; $i++) { if (Test-DpHealthy) { return $true }; Start-Sleep -Seconds 1 }; return $false }
function Wait-CpHealthy { for ($i = 0; $i -lt 30; $i++) { if ((Get-HttpStatus "https://127.0.0.1:$CpPort/healthz") -eq 200) { return $true }; Start-Sleep -Seconds 1 }; return $false }
function Get-InstalledVersion([string]$exe) {
    if (-not (Test-Path $exe)) { return '' }
    try {
        $o = & $exe --version 2>$null
        if (-not $o) { $o = & $exe version 2>$null }
        if ($o) { $p = ("$o" -split '\s+'); if ($p.Count -gt 1) { return $p[1] } }
    } catch { $null = $_ }
    return ''
}
# ---- build identity (see install.sh). The public development version keeps ONE name ("0.3.0-dev") from one publication to the next: the build
# (first 12 hex characters of the published commit) tells two publications apart. '' means unknown; it is shown as "unknown", never as an empty string.
function ConvertTo-Build([string]$b) {
    $b = ("$b").Trim().ToLower()
    if (-not $b -or $b -eq 'unknown' -or $b.Length -gt 40 -or $b -notmatch '^[0-9a-z._-]+$') { return '' }
    return $b
}
function Get-InstalledBuild([string]$exe) {
    if (-not (Test-Path $exe)) { return '' }
    try {
        $o = & $exe --version 2>$null
        if (-not $o) { $o = & $exe version 2>$null }
        if ($o -and ("$o" -match '\(build ([^)\s]+)\)')) { return (ConvertTo-Build $Matches[1]) }
    } catch { $null = $_ }
    return ''
}
# the build of what is installed: the binary's own, else the one the installer recorded in installer.conf for that very version
function Get-InstalledBuildOrRecorded([string]$exe, [string]$ver) {
    $b = Get-InstalledBuild $exe
    if (-not $b -and $ver -and ((Get-ConfValue 'INSTALLED_VERSION') -eq $ver)) { $b = ConvertTo-Build (Get-ConfValue 'INSTALLED_BUILD') }
    return $b
}
function Format-VersionBuild([string]$v, [string]$b) { $b = ConvertTo-Build $b; if (-not $b) { $b = 'unknown' }; return "$v (build $b)" }          # 0.3.0-dev (build a1b2c3d4e5f6)
function Format-VersionBuildShort([string]$v, [string]$b) { $b = ConvertTo-Build $b; if (-not $b) { $b = 'unknown' }; return "$v, build $b" }   # for "(%s)"
function Get-InstalledLabel([string]$exe) {
    $v = Get-InstalledVersion $exe
    if (-not $v) { return '?' }
    return (Format-VersionBuild $v (Get-InstalledBuildOrRecorded $exe $v))
}
# THE rule (the same in the data plane, the control plane and the console): an update exists when the published version is newer, OR the versions
# are equal and the published build differs from the installed one. An installed build that is unknown counts as different; a published build the
# channel does not state cannot differ from anything.  -> newer | rebuilt | older | same
function Get-UpdateState([string]$curV, [string]$curB, [string]$newV, [string]$newB) {
    $cb = ConvertTo-Build $curB; $nb = ConvertTo-Build $newB
    if (Test-SemverLess $curV $newV) { return 'newer' }
    if (Test-SemverLess $newV $curV) { return 'older' }
    if ($nb -and $nb -ne $cb) { return 'rebuilt' }
    return 'same'
}
# the rule applied to every installed component this run touches; 'same' only when each one is
function Get-UpdateVerdict([string]$newV, [string]$newB) {
    $res = 'same'
    foreach ($c in @(@((Test-Path $DpExe), $DpExe, 'dp'), @((Test-Path $CpExe), $CpExe, 'cp'))) {
        if (-not $c[0]) { continue }
        if ($Component -eq 'dp' -and $c[2] -ne 'dp') { continue }
        if ($Component -eq 'cp' -and $c[2] -ne 'cp') { continue }
        $v = Get-InstalledVersion $c[1]
        if (-not $v) { continue }
        $st = Get-UpdateState $v (Get-InstalledBuildOrRecorded $c[1] $v) $newV $newB
        if ($st -eq 'newer') { $res = 'newer' }
        elseif ($st -eq 'rebuilt' -and $res -ne 'newer') { $res = 'rebuilt' }
        elseif ($st -eq 'older' -and $res -eq 'same') { $res = 'older' }
    }
    return $res
}
function Get-LocalIps {
    $ips = @()
    try {
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress })
    } catch {
        try { $ips = @([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike '127.*' } | ForEach-Object { $_.ToString() }) } catch { $ips = @() }
    }
    return @($ips | Sort-Object -Unique)
}
function Get-PublicIp {
    if ($PublicHost) { return $PublicHost }
    foreach ($u in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try { $ip = ("$(Invoke-RestMethod -UseBasicParsing -Uri $u -TimeoutSec 4)").Trim(); if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip } } catch { $null = $_ }
    }
    return ''
}

# ------------------------------------------------------------------------------------------------ panel (toutwaf-cp bootstrap) + summary
# Contract (docs/panel-access.md):
#   toutwaf-cp bootstrap --data DIR [--public-host H] [--listen-port N] [--keep-token] --json
#   toutwaf-cp bootstrap --print-links --data DIR [--setup-token T] --json
# Output is a secret (generated password, setup token): it only lives in $script:Bs, never in the installer log.
function Get-CpExe { if ($env:TOUTWAF_CP_BIN) { return $env:TOUTWAF_CP_BIN } else { return $CpExe } }
function Invoke-CpOffline([string[]]$CpArgs) {   # stdout of `toutwaf-cp <args> --data DIR [--config FILE]`, $null on failure
    $exe = Get-CpExe
    if (-not (Test-Path $exe)) { return $null }
    $a = @($CpArgs) + @('--data', $CpDataDir)
    $cf = Join-Path $ConfDir 'toutwaf-cp.yaml'
    if (Test-Path $cf) { $a += @('--config', $cf) }
    try {
        $global:LASTEXITCODE = 0
        $out = & $exe @a 2>$null
        if ($global:LASTEXITCODE -ne 0 -or -not $out) { return $null }
        return (($out | ForEach-Object { "$_" }) -join "`n")
    } catch { return $null }
}
function Invoke-CpBootstrap([string]$mode, [bool]$keepToken = $false) {
    $script:Bs = $null
    if ($mode -eq 'print-links') { $a = @('bootstrap', '--print-links', '--no-lookup', '--json') }
    else {
        $a = @('bootstrap', '--listen-port', "$CpPort", '--json')
        if ($PublicHost) { $a += @('--public-host', $PublicHost) }
        if ($keepToken) { $a += '--keep-token' }
    }
    $o = Invoke-CpOffline $a
    if (-not $o) { return $false }
    try { $script:Bs = ($o | ConvertFrom-Json) } catch { $script:Bs = $null; return $false }
    if (-not (Get-BsProp 'panel_path')) { $script:Bs = $null; return $false }
    if ($script:Bs.PSObject.Properties.Name -contains 'listen_port' -and $script:Bs.listen_port) { $script:CpPort = [int]$script:Bs.listen_port }
    return $true
}
function Get-BsProp([string]$name) {
    if ($script:Bs -and ($script:Bs.PSObject.Properties.Name -contains $name) -and $null -ne $script:Bs.$name) { return "$($script:Bs.$name)" }
    return ''
}
function Test-CpBootstrapped { return [bool](Invoke-CpOffline @('bootstrap', '--print-links', '--no-lookup', '--json')) }
# the control plane's own list of console URLs (every up non-loopback IPv4 + the public host), as "kind|url" strings
$script:BsLinks = @()
function Update-BsLinks {
    $script:BsLinks = @()
    $o = Invoke-CpOffline @('bootstrap', '--print-links', '--no-lookup', '--json')
    if (-not $o) { return }
    try { $j = $o | ConvertFrom-Json; foreach ($l in @($j.links)) { if ($l.url) { $script:BsLinks += ('{0}|{1}' -f $l.kind, $l.url) } } } catch { $null = $_ }
}
# Install / re-run: bootstrap is idempotent (--keep-token). The account and the secret path exist on a re-run: a setup link for
# an account that was not created now would reopen the web setup of a configured installation, so it is revoked, not shown.
function Initialize-Panel {
    $script:PanelTried = $true
    $keep = Test-CpBootstrapped
    if (-not (Invoke-CpBootstrap 'bootstrap' $keep)) { return $false }
    if ($keep -and (Get-BsProp 'setup_token') -and -not (Get-BsProp 'admin_password')) {
        [void](Invoke-CpOffline @('setup-link', '--revoke', '--json'))
        $script:Bs.setup_token = $null; $script:Bs.setup_path = $null
    }
    $keepBs = $script:Bs
    Update-BsLinks
    $script:Bs = $keepBs
    return $true
}
function Invoke-CpLinks {   # --links: panel path + real links; the user name comes from the account list
    $script:Bs = $null
    if (-not (Invoke-CpBootstrap 'print-links')) { return $false }
    Update-BsLinks
    $o = Invoke-CpOffline @('admin', 'list', '--json')
    if ($o) { try { $u = @($o | ConvertFrom-Json) | Select-Object -First 1; if ($u.username) { $script:Bs | Add-Member -NotePropertyName admin_user -NotePropertyValue "$($u.username)" -Force } } catch { $null = $_ } }
    return $true
}
function Get-SummaryPorts {
    $list = New-Object System.Collections.Generic.List[object]
    if ($Component -ne 'dp') {
        $list.Add(@{ Port = $CpPort; Proto = 'tcp'; Purpose = (T 'p_console') })
        $list.Add(@{ Port = 9444; Proto = 'tcp'; Purpose = (T 'p_dpapi') })
    }
    if ($Component -ne 'cp') {
        $list.Add(@{ Port = $HttpPort; Proto = 'tcp'; Purpose = (T 'p_http') })
        $list.Add(@{ Port = $HttpsPort; Proto = 'tcp'; Purpose = (T 'p_https') })
    }
    return $list
}
function Get-SetupUrls([string]$publicIp) {   # label|url for every local IPv4 and the public address
    $tok = Get-BsProp 'setup_token'
    if (-not $tok) { return @() }
    $pp = (Get-BsProp 'panel_path').Trim('/')
    $sp = Get-BsProp 'setup_path'
    if (-not $sp) { $sp = if ($pp) { "/$pp/setup" } else { '/setup' } }
    if (-not $sp.StartsWith('/')) { $sp = "/$sp" }
    if ($sp -notlike "*$tok*") { $sp = $sp + $(if ($sp.Contains('?')) { "&token=$tok" } else { "?token=$tok" }) }
    $out = @()
    foreach ($ip in @(Get-LocalIps)) { $out += ('{0}: https://{1}:{2}{3}' -f (T 'sum_local'), $ip, $CpPort, $sp) }
    if ($publicIp) { $out += ('{0}: https://{1}:{2}{3}' -f (T 'sum_public'), $publicIp, $CpPort, $sp) }
    elseif ($out.Count -eq 0) { $out += ('{0}: https://{1}:{2}{3}' -f (T 'sum_local'), $env:COMPUTERNAME, $CpPort, $sp) }
    return $out
}

# the summary is a list of rows (kind, text), rendered as boxes on the console or as plain text in the file
function Get-Summary([string]$publicIp) {
    $rows = New-Object System.Collections.Generic.List[object]
    $add = { param($kind, $text) $rows.Add(@{ K = $kind; T = $text }) }
    if ($Component -ne 'dp') {
        & $add 'h' ('{0} - {1}' -f (T 'sum_title'), (T 'sum_panel'))
        $ok = [bool](Get-BsProp 'panel_path')
        if (-not $ok) { & $add 'w' (T 'sum_fallback') }
        $pp = (Get-BsProp 'panel_path').Trim('/')
        $path = if ($pp) { "$pp/" } else { '' }
        $seen = @()
        if ($script:BsLinks.Count -gt 0) {
            foreach ($l in $script:BsLinks) { $k, $u = $l -split '\|', 2; & $add 'u' ('{0}: {1}' -f $(if ($k -eq 'public') { T 'sum_public' } else { T 'sum_local' }), $u); $seen += $u }
        } else { foreach ($ip in (Get-LocalIps)) { & $add 'u' ('{0}: https://{1}:{2}/{3}' -f (T 'sum_local'), $ip, $CpPort, $path) } }
        if ($publicIp) {
            $pu = "https://${publicIp}:$CpPort/$path"
            if ($seen -notcontains $pu) { & $add 'u' ('{0}: {1}' -f (T 'sum_public'), $pu) }
        } else { & $add 'w' (T 'sum_public_unknown') }
        & $add 'd' (T 'sum_tls_note')
        & $add 'e' ''
        if ($ok) {
            & $add 'h' (T 'sum_admin')
            $au = Get-BsProp 'admin_user'
            if ($au) { & $add 'p' ('{0}: {1}' -f (T 'sum_user'), $au) }
            $pw = Get-BsProp 'admin_password'
            if ($pw) { & $add 'p' ('{0}: {1}   ({2})' -f (T 'sum_password'), $pw, (T 'sum_pw_once')) } else { & $add 'p' ('{0}: {1}' -f (T 'sum_password'), (T 'sum_pw_unchanged' @($(if ($au) { $au } else { 'NAME' })))) }
            & $add 'e' ''
            & $add 'h' (T 'sum_setup')
            $su = @(Get-SetupUrls $publicIp)
            if ($su.Count -gt 0) { foreach ($x in $su) { & $add 'u' $x }; & $add 'd' (T 'sum_setup_note') } else { & $add 'p' (T 'sum_setup_none') }
            & $add 'e' ''
        }
    }
    if ($script:CompatLine) { & $add 'h' (T 'sum_compat'); & $add 'p' $script:CompatLine; & $add 'e' '' }
    & $add 'h' (T 'sum_ports')
    $ports = @(Get-SummaryPorts)
    foreach ($p in $ports) { & $add 'p' ('{0}/{1}  {2}' -f $p.Port, $p.Proto, $p.Purpose) }
    & $add 'p' ''
    & $add 'p' ((T 'sum_cmds') + ' (PowerShell, Administrator):')
    $open = @($ports | Where-Object { $_.Port -ne 9444 })
    foreach ($p in $open) { & $add 'p' ("  New-NetFirewallRule -DisplayName 'ToutWAF {0}' -Direction Inbound -Protocol TCP -LocalPort {0} -Action Allow" -f $p.Port) }
    & $add 'p' ('  netsh: ' + (($open | ForEach-Object { 'netsh advfirewall firewall add rule name="ToutWAF {0}" dir=in action=allow protocol=TCP localport={0}' -f $_.Port }) -join ' & '))
    if (@($ports | Where-Object { $_.Port -eq 9444 }).Count -gt 0) {
        & $add 'p' "  9444/tcp: New-NetFirewallRule -DisplayName 'ToutWAF data-plane API' -Direction Inbound -Protocol TCP -LocalPort 9444 -Action Allow -RemoteAddress <DP_IP>"
    }
    & $add 'w' (T 'sum_cloud')
    & $add 'e' ''
    return $rows
}
function Show-Summary([string]$publicIp) {
    $rows = Get-Summary $publicIp
    Write-Host ''
    foreach ($r in $rows) {
        switch ($r.K) {
            'h' { Write-Host ("{0}{1}{2} {3}{4}{5}{0} {6}{5}" -f $script:Acc, $script:Tl, $script:Hr, $script:B, $r.T, $script:R, (Rule (FrameFill $r.T))) }
            'e' { Write-Host ("{0}{1}{2}{3}" -f $script:Acc, $script:Bl, (Rule 77), $script:R); Write-Host '' }
            'u' { $i = $r.T.IndexOf('https://'); Write-Host ("{0}{1}{2} {3}{4}{5}{6}" -f $script:Acc, $script:Vr, $script:R, $r.T.Substring(0, $i), $script:B, $r.T.Substring($i), $script:R) }
            'w' { Write-Host ("{0}{1}{2} {3}{4}{2}" -f $script:Acc, $script:Vr, $script:R, $script:Ylw, $r.T) }
            'd' { Write-Host ("{0}{1}{2} {3}{4}{2}" -f $script:Acc, $script:Vr, $script:R, $script:D, $r.T) }
            default { Write-Host ("{0}{1}{2} {3}" -f $script:Acc, $script:Vr, $script:R, $r.T) }
        }
    }
    if ($Component -eq 'all' -and -not $CpUrl) { Write-Out ('  ' + (T 'sum_node_hint' @((Join-Path $ConfDir 'toutwaf-dp.yaml')))) }
}
function Save-SummaryFile([string]$publicIp) {
    $f = Join-Path $DataRoot 'INSTALL-SUMMARY.txt'
    try {
        # create it empty, restrict it to Administrators / SYSTEM, only then write the secrets
        Set-Content -Path $f -Value '' -Encoding UTF8
        icacls $f /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
        $lines = @(('ToutWAF {0} - {1}Z' -f (T 'sum_title'), (Get-Date).ToUniversalTime().ToString('s')))
        foreach ($r in (Get-Summary $publicIp)) { if ($r.K -eq 'h') { $lines += "== $($r.T)" } elseif ($r.K -eq 'e') { $lines += '' } else { $lines += "   $($r.T)" } }
        Set-Content -Path $f -Value $lines -Encoding UTF8
        Write-Out ('  ' + (T 'sum_file' @($f)))
    } catch { Write-InstallLog "summary file: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------------------------------------ existing install state
function Get-InstallState { return @{ Dp = (Test-Path $DpExe); Cp = (Test-Path $CpExe) } }
function Import-ExistingPorts {
    $f = Join-Path $ConfDir 'toutwaf-cp.yaml'
    if (Test-Path $f) { $m = Select-String -Path $f -Pattern '^\s*console:\s*["'']?[^":'']*:(\d{1,5})' | Select-Object -First 1; if ($m) { $script:CpPort = [int]$m.Matches[0].Groups[1].Value } }
    $f = Join-Path $ConfDir 'toutwaf-dp.yaml'
    if (Test-Path $f) {
        $m = Select-String -Path $f -Pattern '^\s*http:\s*\[\s*"[^"]*:(\d{1,5})"' | Select-Object -First 1; if ($m) { $script:HttpPort = [int]$m.Matches[0].Groups[1].Value }
        $m = Select-String -Path $f -Pattern '^\s*https:\s*\[\s*"[^"]*:(\d{1,5})"' | Select-Object -First 1; if ($m) { $script:HttpsPort = [int]$m.Matches[0].Groups[1].Value }
    }
}
function Set-ComponentFromInstalled {
    $s = Get-InstallState
    if ($s.Dp -and $s.Cp) { $script:Component = 'all' } elseif ($s.Cp) { $script:Component = 'cp' } elseif ($s.Dp) { $script:Component = 'dp' }
}

# ------------------------------------------------------------------------------------------------ status / links
function Invoke-Status {
    Write-Banner
    Box-Top (T 'st_title')
    $s = Get-InstallState
    Import-ExistingPorts
    if (-not $s.Dp -and -not $s.Cp) { Box-Line (T 'state_none'); Box-Bottom; return 1 }
    $rc = 0
    if ($s.Dp) { Box-Line ('toutwaf-dp {0}' -f (Get-InstalledLabel $DpExe)) }
    if ($s.Cp) { Box-Line ('toutwaf-cp {0}' -f (Get-InstalledLabel $CpExe)) }
    Box-Line ((T 'st_channel' @($script:Channel)) + " ($(Get-ChannelBranch))")
    $cj = Get-ChannelJson
    if ($cj) {
        $cexe = if ($s.Dp) { $DpExe } else { $CpExe }
        $cv = Get-InstalledVersion $cexe
        $nb = Get-ChannelBuild $cj
        $st = if ($cv) { Get-UpdateState $cv (Get-InstalledBuildOrRecorded $cexe $cv) ([string]$cj.version) $nb } else { 'same' }
        $lab = Format-VersionBuild ([string]$cj.version) $nb
        if ($st -eq 'newer') { Box-Line ("{0}{1} {2}  -  {3}{4}" -f $script:Ylw, $script:WrM, (T 'st_latest' @($lab)), (T 'st_newer'), $script:R) }
        elseif ($st -eq 'rebuilt') { Box-Line ("{0}{1} {2}  -  {3}{4}" -f $script:Ylw, $script:WrM, (T 'st_latest' @($lab)), (T 'st_newbuild' @('-Update')), $script:R) }
        else { Box-Line (T 'st_latest' @($lab)) }
    } elseif ($script:ChEmpty) {
        Box-Line (T 'st_nochannel')
    }
    $ok = "$($script:Grn)$($script:OkM)"; $no = "$($script:Red)$($script:ErM)"
    foreach ($svc in @(@($s.Dp, $DpService), @($s.Cp, $CpService))) {
        if (-not $svc[0]) { continue }
        $o = Get-Service -Name $svc[1] -ErrorAction SilentlyContinue
        if ($o -and $o.Status -eq 'Running') { Box-Line ('{0}: {1} {2}{3}' -f $svc[1], $ok, (T 'st_active'), $script:R) } else { Box-Line ('{0}: {1} {2}{3}' -f $svc[1], $no, (T 'st_inactive'), $script:R); $rc = 1 }
    }
    $pts = @()
    if ($s.Dp) { $pts += @($HttpPort, $HttpsPort, 9101) }
    if ($s.Cp) { $pts += @($CpPort, 9444) }
    foreach ($p in $pts) { if (Test-Port $p) { Box-Line ('{0}/tcp: {1} {2}{3}' -f $p, $ok, (T 'st_listening'), $script:R) } else { Box-Line ('{0}/tcp: {1} {2}{3}' -f $p, $no, (T 'st_closed'), $script:R); $rc = 1 } }
    if ($s.Dp) { if (Test-DpHealthy) { Box-Line ('http://127.0.0.1:9101/healthz: {0} {1}{2}' -f $ok, (T 'st_healthy'), $script:R) } else { Box-Line ('http://127.0.0.1:9101/healthz: {0} {1}{2}' -f $no, (T 'st_unhealthy'), $script:R); $rc = 1 } }
    if ($s.Cp) { $c = Get-HttpStatus "https://127.0.0.1:$CpPort/healthz"; if ($c -eq 200) { Box-Line ('https://127.0.0.1:{0}/healthz (HTTP {1}): {2} {3}{4}' -f $CpPort, $c, $ok, (T 'st_healthy'), $script:R) } else { Box-Line ('https://127.0.0.1:{0}/healthz: {1} {2}{3}' -f $CpPort, $no, (T 'st_unhealthy'), $script:R); $rc = 1 } }
    Box-Bottom
    return $rc
}
function Invoke-Links {
    Write-Banner
    $s = Get-InstallState
    Import-ExistingPorts
    if (-not $s.Cp) { Write-Out ('  ' + (T 'state_none')); return 1 }
    Set-ComponentFromInstalled
    $pub = Get-PublicIp
    [void](Invoke-CpLinks)
    Show-Summary $pub
    return 0
}

# ------------------------------------------------------------------------------------------------ uninstall
function Invoke-Uninstall {
    Write-Banner
    Box-Top (T 'un_title'); Box-Bottom
    if (Test-Interactive) {
        if (-not (Read-YesNo (T 'q_confirm_un') $false)) { Write-Out ('  ' + (T 'aborted')); return }
        $script:Purge = [switch](Read-YesNo (T 'q_purge') $false)
    }
    Import-ExistingPorts
    foreach ($svc in @($DpService, $CpService)) { Stop-ServiceSafe $svc }
    if (Test-Path $DpExe) { & $DpExe service uninstall 2>$null | Out-Null }
    elseif (Get-Service $DpService -ErrorAction SilentlyContinue) { sc.exe delete $DpService | Out-Null }
    if (Test-Path $CpExe) { & $CpExe service uninstall 2>$null | Out-Null }
    elseif (Get-Service $CpService -ErrorAction SilentlyContinue) { sc.exe delete $CpService | Out-Null }
    # earlier versions of this installer ran the control plane as a scheduled task
    try { Stop-ScheduledTask -TaskName 'ToutWAF-ControlPlane' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName 'ToutWAF-ControlPlane' -Confirm:$false -ErrorAction SilentlyContinue } catch { $null = $_ }
    Get-NetFirewallRule -DisplayName 'ToutWAF*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($path -like "*$InstallDir*") { [Environment]::SetEnvironmentVariable('Path', (($path -split ';' | Where-Object { $_ -and $_ -ne $InstallDir }) -join ';'), 'Machine') }
    Start-Sleep -Seconds 1
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    if ($Purge -and (Test-Path $DataRoot)) { Remove-Item -Recurse -Force $DataRoot; Write-Out ('  {0}{1}{2} {3}' -f $script:Grn, $script:OkM, $script:R, (T 'un_purged')) }
    else { Write-Out ('  {0}{1}{2} {3}' -f $script:Grn, $script:OkM, $script:R, (T 'un_kept' @($ConfDir, $DataDir))) }
    Write-Out ('  ' + (T 'done'))
}

# ------------------------------------------------------------------------------------------------ install / update
# ---- release channel (stable = branch main, dev = branch dev) -------------------------------------------------------
function Get-ConfValue([string]$key) {
    if (Test-Path $ConfFile) { $m = Select-String -Path $ConfFile -Pattern "^$key=(.*)$" | Select-Object -First 1; if ($m) { return $m.Matches[0].Groups[1].Value.Trim() } }
    return ''
}
# precedence: -Channel / TOUTWAF_CHANNEL > a non-stable $DefaultChannel baked into this copy > remembered installer.conf > stable
function Resolve-Channel {
    $c = $Channel
    if (-not $c) { $c = $env:TOUTWAF_CHANNEL }
    if (-not $c -and $DefaultChannel -ne 'stable') { $c = $DefaultChannel }
    if (-not $c) { $c = Get-ConfValue 'CHANNEL' }
    if ($c -eq 'beta') { $c = 'dev' }
    if ($c -ne 'dev') { $c = 'stable' }
    $script:Channel = $c
}
function Get-ChannelBranch { if ($script:Channel -eq 'dev') { return 'dev' } else { return 'main' } }
# Where releases are read: the project's own GitLab first (public project, raw files), the GitHub copy of the same signed channel when it is unreachable.
# Release archives stay verified by the signature key of this installer, whichever source served them. -Repo (another GitHub repository) disables both.
$script:SrcPrimary = if ($env:TOUTWAF_SRC_PRIMARY) { $env:TOUTWAF_SRC_PRIMARY.TrimEnd('/') } else { 'https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw' }
$script:SrcFallback = "https://raw.githubusercontent.com/$Repo"
if ($PSBoundParameters.ContainsKey('Repo')) { $script:SrcPrimary = $script:SrcFallback; $script:SrcFallback = '' }
$script:SrcRoot = ''
function Get-RepoBase {
    if ($BaseUrl) { return $BaseUrl.TrimEnd('/') }
    if ($env:TOUTWAF_BASE_URL) { return $env:TOUTWAF_BASE_URL.TrimEnd('/') }
    $root = if ($script:SrcRoot) { $script:SrcRoot } else { $script:SrcPrimary }
    return "$root/$(Get-ChannelBranch)"
}
# More than one fallback: the sources are tried in the order primary, fallback, fallback2 (the last one is only set by -ViaRepo).
$script:SrcFallback2 = ''
function Step-SrcFallback {
    $chain = @($script:SrcPrimary, $script:SrcFallback, $script:SrcFallback2) | Where-Object { $_ }
    $cur = if ($script:SrcRoot) { $script:SrcRoot } else { $script:SrcPrimary }
    $i = [array]::IndexOf($chain, $cur)
    if ($i -ge 0 -and ($i + 1) -lt $chain.Count) { $script:SrcRoot = $chain[$i + 1]; return $true }
    return $false
}
# -ViaRepo: ToutWAF's own package repository for Windows (tools/repo/README.md) is tried FIRST. It holds the release layout (channel.json, releases/<version>/),
# the winget manifests and a signed index.json. The archive is verified exactly as before (SHA256SUMS + Ed25519 signature of this installer), so the repository
# is a transport, not a trust anchor. If anything is wrong with it the sources stay as they were (GitLab, then GitHub): this switch never blocks an installation.
$script:RepoWindows = if ($env:TOUTWAF_REPO_WINDOWS_URL) { $env:TOUTWAF_REPO_WINDOWS_URL.TrimEnd('/') } else { 'https://repo.qu3ntin.com/include/toutwaf/Windows/-/raw' }
function Use-ViaRepo {
    if ($script:Bound.ContainsKey('Repo')) { Write-Warn '-ViaRepo is ignored with -Repo (another repository was chosen)'; return }
    $root = $script:RepoWindows
    $base = "$root/$(Get-ChannelBranch)"
    try {
        $idxRaw = (Invoke-WebRequest -UseBasicParsing -Uri "$base/index.json" -TimeoutSec 15).Content
        $sumRaw = (Invoke-WebRequest -UseBasicParsing -Uri "$base/index.json.sha256" -TimeoutSec 15).Content
        if ($idxRaw -is [byte[]]) { $idxRaw = [Text.Encoding]::UTF8.GetString($idxRaw) }
        if ($sumRaw -is [byte[]]) { $sumRaw = [Text.Encoding]::UTF8.GetString($sumRaw) }
        $want = ((([string]$sumRaw).Trim()) -split '\s+')[0].ToLowerInvariant()
        $sha = [Security.Cryptography.SHA256]::Create()
        $got = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$idxRaw)) | ForEach-Object { $_.ToString('x2') })
        if ($want -ne $got) { throw 'index.json does not match index.json.sha256' }
        $idx = ([string]$idxRaw) | ConvertFrom-Json
        if ([string]$idx.channel -ne $script:Channel) { throw "the repository serves the $($idx.channel) channel, not $($script:Channel)" }
        $asset = "toutwaf-windows-$(Get-Arch).zip"
        if (@($idx.files | Where-Object { $_.path -eq "releases/$($idx.version)/$asset" }).Count -eq 0) { throw "the repository has no $asset" }
    } catch {
        Write-Warn "-ViaRepo: the ToutWAF package repository is not usable ($($_.Exception.Message)); using the direct download instead (GitLab, then GitHub)"
        return
    }
    $script:SrcFallback2 = $script:SrcFallback; $script:SrcFallback = $script:SrcPrimary; $script:SrcPrimary = $root; $script:SrcRoot = ''
    Write-Info "source: ToutWAF package repository ($base)"
}
function Save-InstallerConf {
    if ($DryRun) { return }
    $text = "# written by install.ps1: release channel used by -Update and by the console update-available check (stable = branch main, dev = branch dev)`nCHANNEL=$($script:Channel)"
    if ((Get-RepoBase) -and ($BaseUrl -or $env:TOUTWAF_BASE_URL)) { $text += "`nBASE_URL=$(Get-RepoBase)" }
    # what this installation runs (see Save-InstalledRecord): kept as it was until the new binaries are in service
    $rv = Get-ConfValue 'INSTALLED_VERSION'; $rb = Get-ConfValue 'INSTALLED_BUILD'
    if ($rv) { $text += "`n# version and build the installer put in service (read by the console when a binary cannot name its own build)`nINSTALLED_VERSION=$rv`nINSTALLED_BUILD=$(if ($rb) { $rb } else { 'unknown' })" }
    try { Set-Content -Path $ConfFile -Value $text -Encoding ASCII } catch { Write-InstallLog "installer.conf: $($_.Exception.Message)" }
}
# remember what is now in service, next to CHANNEL in installer.conf. Installations made before builds existed have no such lines: their build
# reads as unknown, which counts as different from any published build.
function Save-InstalledRecord([string]$ver, [string]$build) {
    if ($DryRun -or -not $ver) { return }
    try {
        $lines = @()
        if (Test-Path $ConfFile) { $lines = @(Get-Content $ConfFile | Where-Object { $_ -notmatch '^(INSTALLED_VERSION|INSTALLED_BUILD)=' -and $_ -notmatch '^# version and build the installer put in service' }) }
        $b = ConvertTo-Build $build; if (-not $b) { $b = 'unknown' }
        $lines += '# version and build the installer put in service (read by the console when a binary cannot name its own build)'
        $lines += "INSTALLED_VERSION=$ver"
        $lines += "INSTALLED_BUILD=$b"
        Set-Content -Path $ConfFile -Value $lines -Encoding ASCII
    } catch { Write-InstallLog "installer.conf: $($_.Exception.Message)" }
}
# true when A < B (pre-release < release; "-dev.N" compared numerically)
function Test-SemverLess([string]$a, [string]$b) {
    $a = $a.TrimStart('v'); $b = $b.TrimStart('v')
    $a = ($a -split '\+')[0]; $b = ($b -split '\+')[0]
    $ac, $ap = $a -split '-', 2; $bc, $bp = $b -split '-', 2
    if ($ac -notmatch '\.') { $ac += '.0' }; if ($bc -notmatch '\.') { $bc += '.0' }
    try { $va = [version]$ac; $vb = [version]$bc } catch { return $false }
    if ($va -ne $vb) { return ($va -lt $vb) }
    if (-not $ap -and -not $bp) { return $false }
    if (-not $bp) { return $true }
    if (-not $ap) { return $false }
    $pa = @($ap -split '\.'); $pb = @($bp -split '\.')
    for ($i = 0; $i -lt [math]::Max($pa.Count, $pb.Count); $i++) {
        if ($i -ge $pa.Count) { return $true }
        if ($i -ge $pb.Count) { return $false }
        $x = $pa[$i]; $y = $pb[$i]
        if ($x -match '^\d+$' -and $y -match '^\d+$') { if ([int]$x -ne [int]$y) { return ([int]$x -lt [int]$y) } }
        elseif ($x -ne $y) { return ([string]::CompareOrdinal($x, $y) -lt 0) }
    }
    return $false
}
$script:ChEmpty = $false
$script:ChQuery = ''
function Get-ChannelJson {
    # $null when unreachable / not JSON / without a version ($script:ChEmpty is then $true when channel.json is valid and says that nothing is published)
    $script:ChEmpty = $false
    foreach ($attempt in 1, 2, 3) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri ((Get-RepoBase) + '/channel.json' + $script:ChQuery) -TimeoutSec 20
            $j = $r.Content | ConvertFrom-Json
            if ($j.PSObject.Properties.Name -contains 'version' -and $j.version) { return $j }
            if ($j.PSObject.Properties.Name -contains 'channel') { $script:ChEmpty = $true }
            break
        } catch {
            Write-InstallLog "channel.json: $($_.Exception.Message)"
            # the primary source is unreachable: the GitHub copy of the same signed channel (not when a mirror or another repository was chosen)
            if (-not $BaseUrl -and -not $env:TOUTWAF_BASE_URL -and (Step-SrcFallback)) { continue }
            break
        }
    }
    return $null
}
function Get-ChannelBuild($j) { if ($j -and ($j.PSObject.Properties.Name -contains 'build')) { return (ConvertTo-Build ([string]$j.build)) } else { return '' } }
# Release signature trust anchor. It lives HERE (in the installer you run), never in channel.json: the copy of the public key that
# channel.json advertises is informational and must not be trusted. Overridden by TOUTWAF_RELEASE_PUBKEY, then by <ConfDir>\release.pub.
# RELEASE_PUBKEY_ID = first 16 hex chars of sha256(raw public key), same as publisher/internal/sign Fingerprint (checked by a test).
$script:ReleasePubKeyDefault = 'V7tJBQsSrIsDTGIqlFhJZ8q4t/Fc8iNvg/cKkfRDATA='
$script:ReleasePubKeyId = 'ebd2a20ce5a5650f'
$script:SigRequiredFrom = '0.2.0-dev.7'   # releases before this one were published unsigned
function Test-CustomPubKey { return [bool]($env:TOUTWAF_RELEASE_PUBKEY -or (Test-Path (Join-Path $ConfDir 'release.pub'))) }
function Get-PubKeyPem([string]$tmp) {
    # TOUTWAF_RELEASE_PUBKEY, else <ConfDir>\release.pub, else the built-in key
    $k = $env:TOUTWAF_RELEASE_PUBKEY
    if (-not $k) { $f = Join-Path $ConfDir 'release.pub'; if (Test-Path $f) { $k = $f } }
    if (-not $k) { $k = $script:ReleasePubKeyDefault }
    $raw = if (Test-Path -LiteralPath $k -ErrorAction SilentlyContinue) { (Get-Content -Raw $k).Trim() } else { $k.Trim() }
    $pem = Join-Path $tmp 'release-pub.pem'
    if ($raw -like '*BEGIN PUBLIC KEY*') { Set-Content -Path $pem -Value $raw -Encoding ASCII }
    else {
        $der = [byte[]]@(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00) + [Convert]::FromBase64String(($raw -replace '\s', ''))
        $b64 = [Convert]::ToBase64String($der)
        Set-Content -Path $pem -Value ("-----BEGIN PUBLIC KEY-----`n" + $b64 + "`n-----END PUBLIC KEY-----") -Encoding ASCII
    }
    return $pem
}
function Get-PubKeyId([string]$pem) {
    # key id of the PEM (last 32 bytes of the SPKI DER = the raw Ed25519 key), no openssl needed
    $b64 = ((Get-Content -Raw $pem) -replace '-----[A-Z ]+-----', '') -replace '\s', ''
    $der = [Convert]::FromBase64String($b64)
    if ($der.Length -lt 32) { return '' }
    $raw = $der[($der.Length - 32)..($der.Length - 1)]
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash([byte[]]$raw)
    return (($h[0..7] | ForEach-Object { $_.ToString('x2') }) -join '')
}
# Policy: a bad signature ALWAYS aborts; a missing one aborts for releases >= SigRequiredFrom and only warns for older (unsigned) ones.
# Windows (.NET, PowerShell 5.1 and 7) has no Ed25519: the check needs openssl.exe. Without it the built-in key cannot be applied: a loud
# warning says so and nothing is reported as verified (SHA-256 was still checked). A key the admin configured explicitly stays fail-closed.
function Confirm-ReleaseSignature([string]$relUrl, [string]$tmp, [string]$query = '') {
    $pem = Get-PubKeyPem $tmp
    $kid = Get-PubKeyId $pem
    $custom = Test-CustomPubKey
    if (-not $custom -and $kid -ne $script:ReleasePubKeyId) { throw "internal error: the built-in release public key has id $kid, expected $($script:ReleasePubKeyId)" }
    $sigPath = Join-Path $tmp 'SHA256SUMS.sig'
    try { Invoke-WebRequest -UseBasicParsing -Uri "$relUrl/SHA256SUMS.sig$query" -OutFile $sigPath }
    catch {
        $sc = 0; try { $sc = [int]$_.Exception.Response.StatusCode } catch { $sc = 0 }
        if ($sc -eq 404) {   # not published
            if (Test-SemverLess $script:ResolvedVersion $script:SigRequiredFrom) { Write-Warn (T 'w_sigold' @($script:ResolvedVersion)); return }
            throw "release signature missing ($relUrl/SHA256SUMS.sig): releases >= $($script:SigRequiredFrom) are signed, installation refused"
        }
        throw "cannot download the release signature ($relUrl/SHA256SUMS.sig)"
    }
    $ossl = Get-Command openssl -ErrorAction SilentlyContinue
    if (-not $ossl) {
        if ($custom) { throw 'a release public key is configured but openssl.exe is not in PATH: cannot verify the Ed25519 signature' }
        Write-Warn (T 'w_sigskip' @($script:ReleasePubKeyId)); return
    }
    $sig = [Convert]::FromBase64String(((Get-Content -Raw $sigPath) -replace '\s', ''))
    $sigFile = Join-Path $tmp 'sums.sig.bin'
    [IO.File]::WriteAllBytes($sigFile, $sig)
    $sums = Join-Path $tmp 'SHA256SUMS'
    & $ossl.Source pkeyutl -verify -pubin -inkey $pem -rawin -in $sums -sigfile $sigFile 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & $ossl.Source pkeyutl -verify -pubin -inkey $pem -in $sums -sigfile $sigFile 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'release signature verification FAILED' }
    }
    Write-Info (T 's_sigok' @($kid))
}
$script:ChJson = $null
function Resolve-Release {
    # sets $script:ResolvedVersion
    $pinned = ($Version -ne 'latest')
    if ($ViaRepo -and -not $BaseUrl -and -not $env:TOUTWAF_BASE_URL) { Use-ViaRepo }
    $script:ChJson = Get-ChannelJson
    $script:NewBuild = ''
    if (-not $script:ChJson) {
        if ($script:ChEmpty -and -not $pinned) {
            # not a network problem: the channel is reachable and says that no version is published on it. Say that, and what to do.
            $other = if ($script:Channel -eq 'dev') { 'stable' } else { 'dev' }
            throw (T 'e_nover' @($script:Channel, $other, $other))
        }
        if (-not $pinned) { throw "cannot read $(Get-RepoBase)/channel.json (channel $($script:Channel)): check the network, use -BaseUrl, -Version or -ZipPath" }
        Write-Warn 'cannot read channel.json: yanked / minimum-installer checks skipped'
    }
    if ($script:ChJson -and ($script:ChJson.PSObject.Properties.Name -contains 'min_installer') -and $script:ChJson.min_installer) {
        if (Test-SemverLess $script:InstallerVersion ([string]$script:ChJson.min_installer)) { throw (T 'e_installer_old' @([string]$script:ChJson.min_installer)) }
    }
    $v = if ($pinned) { $Version.TrimStart('v') } else { [string]$script:ChJson.version }
    $yanked = @(); if ($script:ChJson -and ($script:ChJson.PSObject.Properties.Name -contains 'yanked') -and $script:ChJson.yanked) { $yanked = @($script:ChJson.yanked) }
    if ($yanked -contains $v -and -not $Force) { throw (T 'e_yanked' @($v)) }
    $script:ResolvedVersion = $v
    if ($script:ChJson -and ([string]$script:ChJson.version) -eq $v) { $script:NewBuild = Get-ChannelBuild $script:ChJson }
}

# The public mirror (raw.githubusercontent.com) caches for a few minutes, and a development version is republished under the SAME path: right after a
# publication an installer could read the new channel.json with the old SHA256SUMS. Every file of a release directory is therefore asked for with a
# cache-bypass parameter that belongs to the publication, "?b=<build>" (the build read in channel.json). No build announced (older channel.json, a version
# pinned that is not the channel's): no parameter. A file mirror has no cache: no parameter either.
function Get-ReleaseQuery {
    $b = ''
    if ($script:ChJson -and ([string]$script:ChJson.version) -eq $script:ResolvedVersion) { $b = Get-ChannelBuild $script:ChJson }
    if ($b -and ((Get-RepoBase) -match '^https?://')) { return "?b=$b" }
    return ''
}
# One more read of channel.json, with its own cache-bypass parameter "?t=<date>", after the files of a release disagreed with each other.
function Update-ChannelOnce {
    if ((Get-RepoBase) -match '^https?://') { $script:ChQuery = '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    try { $j = Get-ChannelJson } finally { $script:ChQuery = '' }
    if (-not $j) { return $false }
    $script:ChJson = $j
    if ($Version -eq 'latest') { $script:ResolvedVersion = [string]$j.version }
    if (([string]$j.version) -eq $script:ResolvedVersion) { $script:NewBuild = Get-ChannelBuild $j }
    return $true
}
# ------------------------------------------------------------------------------------------------ extras
# The second asset of a release: toutwaf-extras.tar.gz, or toutwaf-extras-<n>of<m>.tar.gz when cut. It holds toutwaf-extras-<version>\{agent-dist\toutwaf-agent-windows-*.exe,
# av-dist\toutwaf-av-*, LICENSE, VERSION, BUILD} and is listed in the signed SHA256SUMS, so the signature check of the archive covers it too (deploy/RELEASE-LAYOUT.md).
# Nothing about the extras is ever fatal here: an installation without them works and does not offer Windows servers nor the antivirus (the console says so).
$script:ExtrasDir = ''; $script:ExtrasResult = ''; $script:ExtrasCount = 0; $script:ExtrasVersion = ''; $script:ExtrasBuild = ''
# the programs the contract names, nothing else (a file with another name, or a link, is never installed)
function Get-ExtrasFiles([string]$dir) {
    $out = @()
    $pairs = @(@('agent-dist', '^toutwaf-agent-windows-(amd64|arm64)\.exe$'), @('av-dist', '^toutwaf-av-(linux-(amd64|arm64)|darwin-(amd64|arm64)|windows-(amd64|arm64)\.exe)$'))
    foreach ($pair in $pairs) {
        $src = Join-Path $dir $pair[0]
        if (-not (Test-Path $src)) { continue }
        foreach ($f in @(Get-ChildItem -Path $src -File -Force | Where-Object { $_.Name -cmatch $pair[1] -and -not $_.LinkType })) { $out += ,@($pair[0], $f) }
    }
    return $out
}
function Get-ExtrasSkipped { return ($NoExtras -or $env:TOUTWAF_NO_EXTRAS -in @('1', 'yes', 'true', 'on')) }
function Set-ExtrasFailed([string]$key, [object[]]$a) { $script:ExtrasResult = 'failed'; $script:ExtrasDir = ''; Write-Warn (T $key $a) }
function Expand-ExtrasParts([string[]]$files, [string]$tmp) {
    $out = Join-Path $tmp 'extras-out'
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { Set-ExtrasFailed 'w_extras_bad' @((Split-Path $files[0] -Leaf)); return }
    foreach ($f in $files) {
        & $tar.Source -xzf $f -C $out 2>$null
        if ($LASTEXITCODE -ne 0) { Set-ExtrasFailed 'w_extras_bad' @((Split-Path $f -Leaf)); return }
    }
    $d = Get-ChildItem -Path $out -Directory -Filter 'toutwaf-extras-*' | Select-Object -First 1
    if (-not $d) { Set-ExtrasFailed 'w_extras_bad' @((Split-Path $files[0] -Leaf)); return }
    $v = ''; $b = ''
    if (Test-Path (Join-Path $d.FullName 'VERSION')) { $v = (Get-Content (Join-Path $d.FullName 'VERSION') -TotalCount 1).Trim() }
    if (Test-Path (Join-Path $d.FullName 'BUILD')) { $b = ConvertTo-Build (Get-Content (Join-Path $d.FullName 'BUILD') -TotalCount 1) }
    $av = $script:Rel.ArchiveVersion; $ab = $script:Rel.ArchiveBuild
    if ($av -and $v -and $v -ne $av) { Set-ExtrasFailed 'w_extras_ver' @($v, $av); return }
    if ($ab -and $b -and $b -ne $ab) { Set-ExtrasFailed 'w_extras_ver' @("$v ($b)", "$av ($ab)"); return }
    $n = @(Get-ExtrasFiles $d.FullName).Count
    if ($n -eq 0) { Set-ExtrasFailed 'w_extras_bad' @((Split-Path $files[0] -Leaf)); return }
    $script:ExtrasDir = $d.FullName; $script:ExtrasCount = $n
    $script:ExtrasVersion = if ($v) { $v } else { $av }; $script:ExtrasBuild = if ($b) { $b } else { $ab }
}
function Get-Extras([string]$rel, [string]$tmp, [string]$q) {
    $script:ExtrasDir = ''; $script:ExtrasResult = ''
    if (Get-ExtrasSkipped) { $script:ExtrasResult = 'skipped'; return }
    if ($Component -eq 'dp') { $script:ExtrasResult = 'skipped'; return }
    if ($ExtrasPath -and $ExtrasPath.Count -gt 0) {
        foreach ($f in $ExtrasPath) { if (-not (Test-Path -LiteralPath $f)) { Set-ExtrasFailed 'w_extras_nofile' @($f); return } }
        foreach ($f in $ExtrasPath) {
            $n = Split-Path $f -Leaf; $sums = Join-Path (Split-Path (Resolve-Path -LiteralPath $f).Path -Parent) 'SHA256SUMS'
            if (Test-Path $sums) {
                $line = Get-Content $sums | Where-Object { $_ -match ([regex]::Escape($n) + '$') } | Select-Object -First 1
                $want = if ($line) { ($line -split '\s+')[0].ToLower() } else { '' }
                if (-not $want -or $want -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLower()) { Set-ExtrasFailed 'w_extras_sum' @($n); return }
            } else { Write-Info (T 's_extras_unchecked' @($n)) }
        }
        Expand-ExtrasParts @($ExtrasPath | ForEach-Object { (Resolve-Path -LiteralPath $_).Path }) $tmp
        return
    }
    if ($ZipPath) { $script:ExtrasResult = 'none'; return }
    $sumsFile = Join-Path $tmp 'SHA256SUMS'
    $names = @(Get-Content $sumsFile | ForEach-Object { if ($_ -match '^[0-9a-fA-F]{64}\s+(toutwaf-extras(-[0-9]+of[0-9]+)?\.tar\.gz)$') { $Matches[1] } })
    if ($names.Count -eq 0) { $script:ExtrasResult = 'none'; return }
    $names = @($names | Sort-Object { if ($_ -match '-([0-9]+)of') { [int]$Matches[1] } else { 0 } })
    if ($names[0] -match 'of([0-9]+)\.tar\.gz$') { if ([int]$Matches[1] -ne $names.Count) { Set-ExtrasFailed 'w_extras_inc' @($names.Count, $Matches[1]); return } }
    $files = @(); $total = 0
    foreach ($n in $names) {
        $f = Join-Path $tmp $n
        $ok = $false
        for ($i = 1; $i -le 2 -and -not $ok; $i++) {
            try { Invoke-WebRequest -UseBasicParsing -Uri "$rel/$n$q" -OutFile $f; $ok = (Test-Path $f) } catch { if (Test-Path $f) { Remove-Item $f -Force } }
        }
        if (-not $ok) { Set-ExtrasFailed 'w_extras_dl' @($n); return }
        $line = Get-Content $sumsFile | Where-Object { $_ -match ([regex]::Escape($n) + '$') } | Select-Object -First 1
        $want = ($line -split '\s+')[0].ToLower()
        $got = (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower()
        if ($want -ne $got) { Set-ExtrasFailed 'w_extras_sum' @($n); return }
        if ($script:ChJson -and [string]$script:ChJson.version -eq $script:ResolvedVersion) {
            $a = @($script:ChJson.assets | Where-Object { $_.name -eq $n }) | Select-Object -First 1
            if ($a -and $a.sha256 -and ([string]$a.sha256).ToLower() -ne $got) { Set-ExtrasFailed 'w_extras_sum' @($n); return }
        }
        $total += (Get-Item $f).Length; $files += $f
    }
    Write-Info (T 's_extras_sha' @($names.Count, [int]($total / 1MB)))
    Expand-ExtrasParts $files $tmp
}
function Install-Extras {
    if (-not $script:ExtrasDir) { return }
    $n = 0; $names = @()
    foreach ($e in @(Get-ExtrasFiles $script:ExtrasDir)) {
        $dst = Join-Path $CpDataDir $e[0]
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        $f = $e[1]
        # a copy next to the final name, moved over it: a program being downloaded by a machine is never half replaced
        Copy-Item $f.FullName (Join-Path $dst ($f.Name + '.new')) -Force
        Move-Item (Join-Path $dst ($f.Name + '.new')) (Join-Path $dst $f.Name) -Force
        $n++; $names += $f.Name
    }
    $json = '{"version":"' + $script:ExtrasVersion + '","build":"' + $script:ExtrasBuild + '","installed_at":"' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') + '","files":[' + (($names | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']}'
    Set-Content -Path (Join-Path $CpDataDir 'extras.json') -Value $json -Encoding ASCII
    $script:ExtrasResult = 'ok'; $script:ExtrasCount = $n
    Write-Info (T 's_extras_ok' @($n, $CpDataDir))
}
function Test-ExtrasCurrent([string]$v, [string]$b) {
    $j = Join-Path $CpDataDir 'extras.json'
    if (-not (Test-Path $j)) { return $false }
    $raw = Get-Content -Raw $j
    if ($raw -notmatch '"version":"([^"]*)"' -or $Matches[1] -ne $v) { return $false }
    if ($b) { if ($raw -notmatch '"build":"([^"]*)"' -or $Matches[1] -ne $b) { return $false } }
    foreach ($m in [regex]::Matches($raw, '"(toutwaf-[^"]+)"')) {
        $f = $m.Groups[1].Value
        $d = if ($f -like 'toutwaf-agent-*') { 'agent-dist' } else { 'av-dist' }
        if (-not (Test-Path (Join-Path (Join-Path $CpDataDir $d) $f))) { return $false }
    }
    return $true
}
# an update that finds nothing new for the programs still brings the extras when they are missing or of another build
function Invoke-ExtrasMaintain([string]$tmp, [string]$v, [string]$b) {
    if ($Component -eq 'dp' -or (Get-ExtrasSkipped)) { return }
    if ($ZipPath -and -not $ExtrasPath) { return }
    if (Test-ExtrasCurrent $v $b) { return }
    $rel = if ($ZipPath) { '' } else { (Get-RepoBase) + '/releases/' + $script:ResolvedVersion }
    if (-not $ZipPath -and -not (Test-Path (Join-Path $tmp 'SHA256SUMS'))) {
        $q = Get-ReleaseQuery
        try { Invoke-WebRequest -UseBasicParsing -Uri "$rel/SHA256SUMS$q" -OutFile (Join-Path $tmp 'SHA256SUMS') } catch { Write-Warn (T 'w_extras_dl' @('SHA256SUMS')); return }
        Confirm-ReleaseSignature $rel $tmp $q
    }
    $script:Rel = @{ ArchiveVersion = $v; ArchiveBuild = $b }
    Invoke-Step (T 's_extras') { Get-Extras $rel $tmp (Get-ReleaseQuery) }
    Install-Extras
    Write-ExtrasReport
}
function Write-ExtrasReport {
    switch ($script:ExtrasResult) {
        'ok' { Write-Out ('  {0} {1}' -f $script:Bul, (T 's_extras_ok' @($script:ExtrasCount, $CpDataDir))) }
        'none' { Write-Out ('  {0} {1}' -f $script:Bul, (T 'w_extras_none')) }
        'failed' { Write-Out ('  {0} {1}' -f $script:Bul, (T 'w_extras_todo' @('install.ps1 -Update'))) }
    }
}

function Get-Release([string]$tmp) {
    $arch = Get-Arch
    $zip = $ZipPath
    $resolved = 'local'
    if (-not $zip) {
        $name = "toutwaf-windows-$arch.zip"
        $zip = Join-Path $tmp $name
        $attempt = 1
        while ($true) {
            $resolved = $script:ResolvedVersion
            $rel = (Get-RepoBase) + "/releases/$resolved"
            $q = Get-ReleaseQuery
            Invoke-WebRequest -UseBasicParsing -Uri "$rel/$name$q" -OutFile $zip
            Invoke-WebRequest -UseBasicParsing -Uri "$rel/SHA256SUMS$q" -OutFile (Join-Path $tmp 'SHA256SUMS')
            $line = Get-Content (Join-Path $tmp 'SHA256SUMS') | Where-Object { $_ -match ([regex]::Escape($name) + '$') } | Select-Object -First 1
            if (-not $line) { throw "No checksum published for $name" }
            $want = ($line -split '\s+')[0].ToLower()
            $got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
            $which = ''
            if ($want -ne $got) { $which = 'SHA256SUMS' }
            elseif ($script:ChJson -and [string]$script:ChJson.version -eq $resolved) {
                $a = @($script:ChJson.assets | Where-Object { $_.name -eq $name }) | Select-Object -First 1
                if ($a -and $a.sha256 -and ([string]$a.sha256).ToLower() -ne $got) { $which = 'channel.json' }
            }
            if (-not $which) { break }
            # the files do not agree with each other. Once: read channel.json again past the cache, then start over; the second time: stop, saying why and what to do
            if ($attempt -eq 1 -and (Update-ChannelOnce)) { $attempt = 2; Write-Warn (T 'w_mirror' @($name)); continue }
            throw (T 'e_mismatch' @($name, $which))
        }
        Write-Info (T 's_sha')
        Confirm-ReleaseSignature $rel $tmp $q
    } elseif (-not (Test-Path $zip)) { throw "Zip not found: $zip" }
    $stage = Join-Path $tmp 'stage'
    Expand-Archive -Path $zip -DestinationPath $stage -Force
    # layout: toutwaf-<version>-windows-<arch>\bin\*.exe (a flat archive works too)
    $all = @(Get-ChildItem -Path $stage -Recurse -Filter 'toutwaf*.exe')
    # the host agent builds (agent-dist) and the ToutWAF Antivirus programs (av-dist) are served by the control plane, they are not installed as programs
    $bins = @($all | Where-Object { $_.FullName -notmatch '[\\/](agent-dist|av-dist)[\\/]' })
    if ($bins.Count -eq 0) { throw 'No binaries found in the release archive' }
    $agentDist = Get-ChildItem -Path $stage -Recurse -Directory -Filter 'agent-dist' | Select-Object -First 1
    $avDist = Get-ChildItem -Path $stage -Recurse -Directory -Filter 'av-dist' | Select-Object -First 1
    # the archive says what it holds: VERSION and BUILD next to bin\ (older archives have no BUILD)
    $idFiles = @(Get-ChildItem -Path $stage -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/](agent-dist|av-dist)[\\/]' })
    $vf = $idFiles | Where-Object { $_.Name -ceq 'VERSION' } | Select-Object -First 1
    $bf = $idFiles | Where-Object { $_.Name -ceq 'BUILD' } | Select-Object -First 1
    $archVer = if ($vf) { (Get-Content $vf.FullName -TotalCount 1).Trim() } else { '' }
    $archBuild = if ($bf) { ConvertTo-Build (Get-Content $bf.FullName -TotalCount 1) } else { '' }
    return @{ Version = $resolved; ArchiveVersion = $archVer; ArchiveBuild = $archBuild; Bins = $bins; AgentDist = $(if ($agentDist) { $agentDist.FullName } else { '' }); AVDist = $(if ($avDist) { $avDist.FullName } else { '' }) }
}

function Set-Acls {
    # SYSTEM + Administrators full; the service account (LocalService) modifies data/logs only; config is read-only for it
    icacls $DataRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    icacls $DataDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
    icacls $LogDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
    icacls $ConfDir /grant '*S-1-5-19:(OI)(CI)RX' | Out-Null
}

function Write-Configs {
    $dpConf = Join-Path $ConfDir 'toutwaf-dp.yaml'
    if ($Component -ne 'cp') {
        if (-not (Test-Path $dpConf)) {
            $y = @"
# ToutWAF data plane - node configuration (full reference: toutwaf-dp.exe print-config)
group: $Group
data_dir: '$($DataDir -replace '\\','/')'
certs_dir: '$($CertsDir -replace '\\','/')'
listen:
  http: ["0.0.0.0:$HttpPort"]
  https: ["0.0.0.0:$HttpsPort"]
admin:
  listen: 127.0.0.1:9101
tls:
  profile: intermediate
logging:
  level: info
  json: true
"@
            if ($CpUrl) {
                $y += "`ncontrol_plane:`n  url: $CpUrl`n"
                if ($NodeToken) { $y += "  token: $NodeToken`n" }
                if ($EnrollToken) { $y += "  enroll_token: $EnrollToken`n" }
                if ($CpCa) {
                    $caDst = Join-Path $ConfDir 'cp-ca.pem'
                    if ($CpCa -match '^https?://') { Invoke-WebRequest -UseBasicParsing -Uri $CpCa -OutFile $caDst } elseif (Test-Path $CpCa) { Copy-Item $CpCa $caDst -Force } else { throw "-CpCa: file not found: $CpCa" }
                    $y += "  ca_file: '$($caDst -replace '\\','/')'`n"
                } elseif ($CpUrl -match '^https://(127\.0\.0\.1|localhost|\[::1\])[:/]') {
                    $y += "  ca_file: '$((Join-Path $CpDataDir 'tls\console.crt') -replace '\\','/')'`n"
                }
            } else {
                $y += "`npolicy_file: '$(($ConfDir -replace '\\','/'))/policy.yaml'`n"
                $pol = Join-Path $ConfDir 'policy.yaml'
                if (-not (Test-Path $pol)) {
                    Set-Content -Path $pol -Encoding UTF8 -Value "version: 1`nnode_group: default`napps:`n  - id: example`n    name: Example application`n    hostnames: [example.com]`n    origins:`n      - url: http://127.0.0.1:8080`n    mode: detect`n    settings:`n      REDIRECT_HTTP_TO_HTTPS: false`n      HSTS: false`n"
                }
            }
            Set-Content -Path $dpConf -Value $y -Encoding UTF8
            Write-Info "wrote $dpConf"
        } else { Write-Info "keeping existing $dpConf" }
    }
    if ($Component -ne 'dp') {
        $cpConf = Join-Path $ConfDir 'toutwaf-cp.yaml'
        if (-not (Test-Path $cpConf)) {
            $pub = if ($PublicHost) { $PublicHost } else { $env:COMPUTERNAME }
            Set-Content -Path $cpConf -Encoding UTF8 -Value "data_dir: '$(($CpDataDir -replace '\\','/'))'`npublic_url: https://${pub}:$CpPort`nlisten:`n  console: ':$CpPort'`n  dp: ':9444'`ndatabase:`n  driver: sqlite`ndataplane:`n  inspect_url: http://127.0.0.1:9101/debug/inspect`ntelemetry:`n  enabled: $(if (Test-NoTelemetry) { 'false' } else { 'true' })`n"
            Write-Info "wrote $cpConf"
        } else { Write-Info "keeping existing $cpConf" }
    }
}

function Register-Services {
    $dpConf = Join-Path $ConfDir 'toutwaf-dp.yaml'
    $cpConf = Join-Path $ConfDir 'toutwaf-cp.yaml'
    $start = if ($NoEnable) { 'demand' } else { 'auto' }
    if ($Component -ne 'cp') {
        if (-not (Get-Service $DpService -ErrorAction SilentlyContinue)) {
            & $DpExe --config $dpConf service install
            if ($LASTEXITCODE -ne 0) { throw "toutwaf-dp service install failed (exit $LASTEXITCODE)" }
        }
        sc.exe config $DpService obj= 'NT AUTHORITY\LocalService' start= $start | Out-Null
        sc.exe failure $DpService reset= 86400 actions= restart/2000/restart/5000/restart/30000 | Out-Null
        sc.exe failureflag $DpService 1 | Out-Null
        sc.exe sidtype $DpService unrestricted | Out-Null
    }
    if ($Component -ne 'dp') {
        # the control plane ships its own service wrapper (toutwaf-cp service install); earlier versions of this installer used a scheduled task
        try { Stop-ScheduledTask -TaskName 'ToutWAF-ControlPlane' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName 'ToutWAF-ControlPlane' -Confirm:$false -ErrorAction SilentlyContinue } catch { $null = $_ }
        if (-not (Get-Service $CpService -ErrorAction SilentlyContinue)) {
            & $CpExe service install -config $cpConf
            if ($LASTEXITCODE -ne 0) { throw "toutwaf-cp service install failed (exit $LASTEXITCODE)" }
        }
        sc.exe config $CpService obj= 'NT AUTHORITY\LocalService' start= $start | Out-Null
        sc.exe failure $CpService reset= 86400 actions= restart/2000/restart/5000/restart/30000 | Out-Null
        sc.exe failureflag $CpService 1 | Out-Null
    }
}

function Set-Firewall {
    # one rule per purpose, re-created on every run so that port changes and upgrades from older installs are picked up.
    # HTTP/3 (QUIC, UDP 443) is not implemented by the data plane: the former 'ToutWAF HTTP/3' rule is removed, nothing opens UDP.
    Get-NetFirewallRule -DisplayName 'ToutWAF HTTP/3' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    if ($Component -ne 'cp') {
        $name = 'ToutWAF HTTP/HTTPS'
        Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $HttpPort, $HttpsPort -Program $DpExe -Profile Any | Out-Null
    }
    if ($Component -ne 'dp') {
        $name = 'ToutWAF Console'
        Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        # same default as the Linux installer: opened automatically (every profile), -ConsoleFrom restricts it to one address / network,
        # -NoFirewall opts out. The data-plane API port (9444) is never opened here.
        $rule = @{ DisplayName = $name; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'; LocalPort = $CpPort; Program = $CpExe; Profile = 'Any' }
        if ($ConsoleFrom) { $rule['RemoteAddress'] = $ConsoleFrom }
        New-NetFirewallRule @rule | Out-Null
        if ($ConsoleFrom) { Write-Info (T 'fw_console_from' @($CpPort, $ConsoleFrom)) } else { Write-Warn (T 'fw_console_open' @($CpPort)) }
        Write-Warn ((T 'p_dpapi_warn') + ' (New-NetFirewallRule -RemoteAddress)')
    }
}

function Backup-BeforeUpdate([string]$backupRoot, [hashtable]$state) {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $dir = Join-Path $backupRoot "pre-update-$ts"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -Path $ConfDir -Destination (Join-Path $dir 'config') -Recurse -Force
    if ($state.Cp -and $Component -ne 'dp') {
        Stop-ServiceSafe $CpService     # consistent copy of the SQLite files; restarted below
        if (Test-Path $CpDataDir) {
            $db = Join-Path $dir 'db'
            New-Item -ItemType Directory -Path $db -Force | Out-Null
            Get-ChildItem -Path $CpDataDir -File | Where-Object { $_.Name -like 'toutwaf.db*' -or $_.Name -eq 'master.key' } | Copy-Item -Destination $db -Force
        }
        $script:DbBackup = Join-Path $dir 'db'
    }
    Get-ChildItem -Path $backupRoot -Directory -Filter 'pre-update-*' | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Info "backup written to $dir"
}
function Restore-Dp {
    Write-Warn (T 'w_rollback')
    Stop-ServiceSafe $DpService
    $prev = Join-Path (Join-Path $DataRoot 'backup') 'toutwaf-dp.exe.prev'
    if (Test-Path $prev) { Copy-Item $prev $DpExe -Force; Start-Service -Name $DpService }
}
function Restore-Cp {
    Write-Warn (T 'w_rollback')
    Stop-ServiceSafe $CpService
    $prev = Join-Path (Join-Path $DataRoot 'backup') 'toutwaf-cp.exe.prev'
    if (Test-Path $prev) {
        Copy-Item $prev $CpExe -Force
        if ($script:DbBackup -and (Test-Path $script:DbBackup)) { Copy-Item (Join-Path $script:DbBackup '*') $CpDataDir -Force }
        Start-Service -Name $CpService
    }
}

function Invoke-InstallFlow([string]$action) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('toutwaf-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $script:DbBackup = ''
    try {
        $script:NewBuild = ''
        if (-not $ZipPath) { Resolve-Release }
        if ($action -eq 'update' -and -not $ZipPath -and -not $Force) {
            # THE rule, before anything is downloaded: same version AND same build as the channel's = nothing to do. (A channel that does not state
            # its build cannot tell: the archive is downloaded and its files are compared, as before.)
            $verdict = Get-UpdateVerdict $script:ResolvedVersion $script:NewBuild
            if ($verdict -eq 'same' -and $script:NewBuild) {
                Write-Out ('  {0}{1}{2} {3}' -f $script:Grn, $script:OkM, $script:R, (T 'up_to_date' @((Format-VersionBuildShort $script:ResolvedVersion $script:NewBuild))))
                Invoke-ExtrasMaintain $tmp $script:ResolvedVersion $script:NewBuild
                return $null
            }
            if ($verdict -eq 'rebuilt') {
                $curExe = if (Test-Path $DpExe) { $DpExe } else { $CpExe }
                Write-Out ('  {0} {1}' -f $script:Bul, (T 'up_rebuilt' @((Get-InstalledLabel $curExe), (Format-VersionBuild $script:ResolvedVersion $script:NewBuild))))
            }
        }
        $verLabel = if ($ZipPath) { 'local' } else { $script:ResolvedVersion }
        Invoke-Step (T 's_fetch' @($verLabel, (Get-Arch))) { $script:Rel = Get-Release $tmp }
        if ($Component -ne 'dp' -and -not (Get-ExtrasSkipped)) {
            $xrel = if ($ZipPath) { '' } else { (Get-RepoBase) + '/releases/' + $script:ResolvedVersion }
            Invoke-Step (T 's_extras') { Get-Extras $xrel $tmp (Get-ReleaseQuery) }
        }
        $newBuild = if ($script:Rel.ArchiveBuild) { $script:Rel.ArchiveBuild } else { $script:NewBuild }
        $bins = $script:Rel.Bins
        $state = Get-InstallState
        $backup = Join-Path $DataRoot 'backup'
        if ($action -eq 'update') {
            $same = $true
            foreach ($b in $bins) {
                if (($Component -eq 'dp') -and $b.Name -notlike 'toutwaf-dp*') { continue }
                if (($Component -eq 'cp') -and $b.Name -like 'toutwaf-dp*') { continue }
                $dst = Join-Path $InstallDir $b.Name
                if (-not (Test-Path $dst) -or (Get-FileHash $dst -Algorithm SHA256).Hash -ne (Get-FileHash $b.FullName -Algorithm SHA256).Hash) { $same = $false }
            }
            $curV = if ($state.Dp) { Get-InstalledVersion $DpExe } else { Get-InstalledVersion $CpExe }
            if ($curV -and -not $ZipPath -and (Test-SemverLess $script:ResolvedVersion $curV) -and -not $Force) { throw (T 'e_downgrade' @($script:ResolvedVersion, $script:Channel, $curV)) }
            if ($same -and -not $Force) {
                $curExe = if ($state.Dp) { $DpExe } else { $CpExe }
                $cur = Get-InstalledVersion $curExe
                $curB = Get-InstalledBuildOrRecorded $curExe $cur
                if (-not $cur) { $cur = if ($script:Rel.ArchiveVersion) { $script:Rel.ArchiveVersion } else { $script:Rel.Version } }
                if (-not $curB) { $curB = $newBuild }
                Write-Out ('  {0}{1}{2} {3}' -f $script:Grn, $script:OkM, $script:R, (T 'up_to_date' @((Format-VersionBuildShort $cur $curB))))
                # the files are the archive's: whatever the binaries cannot say of themselves, the archive does
                Save-InstalledRecord $cur $curB
                if ($script:ExtrasDir) { Install-Extras; Write-ExtrasReport } else { Invoke-ExtrasMaintain $tmp $cur $curB }
                return $null
            }
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            Invoke-Step (T 's_backup') { Backup-BeforeUpdate $backup $state }
        }
        $oldDp = Get-InstalledLabel $DpExe; if ($oldDp -eq '?') { $oldDp = '' }
        Invoke-Step (T 's_user') {
            if (-not (Test-Path $ConfDir)) { New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null }
            foreach ($d in @($InstallDir, $ConfDir, $DataDir, $LogDir, $CertsDir, (Join-Path $DataDir 'spool'), $CpDataDir, $backup)) {
                if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            }
            Set-Acls
        }
        Save-InstallerConf
        Invoke-Step (T 's_bin') {
            foreach ($s in @($DpService, $CpService)) { Stop-ServiceSafe $s }
            foreach ($b in $bins) {
                if (($Component -eq 'dp') -and $b.Name -notlike 'toutwaf-dp*') { continue }
                if (($Component -eq 'cp') -and $b.Name -like 'toutwaf-dp*') { continue }
                $dst = Join-Path $InstallDir $b.Name
                if (Test-Path $dst) { Copy-Item $dst (Join-Path $backup ($b.Name + '.prev')) -Force }
                Copy-Item $b.FullName $dst -Force
                Write-Info "installed $dst"
            }
        }
        if ($Component -ne 'dp' -and $script:Rel.AgentDist) {
            # served to the servers of the cluster by the control plane (replaced at every update)
            $agentDst = Join-Path $CpDataDir 'agent-dist'
            New-Item -ItemType Directory -Path $agentDst -Force | Out-Null
            Copy-Item -Path (Join-Path $script:Rel.AgentDist 'toutwaf-agent-*') -Destination $agentDst -Force
            Write-Info "host agent builds installed in $agentDst"
        }
        # the Windows agents and the antivirus programs come with the extras of the release (a second asset): installed next to the data of the control plane
        if ($Component -ne 'dp') { Install-Extras }
        Invoke-Step (T 's_cfg') { Write-Configs }
        Invoke-Step (T 's_units') {
            Register-Services
            $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
            if ($machinePath -notlike "*$InstallDir*") { [Environment]::SetEnvironmentVariable('Path', "$machinePath;$InstallDir", 'Machine') }
        }
        if (-not $NoFirewall) { Invoke-Step (T 's_fw') { Set-Firewall } }
        if ($Component -ne 'dp') { Invoke-Step (T 's_boot') { [void](Initialize-Panel) } }
        if (-not $NoStart) {
            Invoke-Step (T 's_start') {
                if ($Component -ne 'dp') {
                    Start-Service -Name $CpService
                    if (-not (Wait-CpHealthy)) {
                        if ($action -eq 'update') { Restore-Cp }
                        Write-Warn "toutwaf-cp does not answer on :$CpPort yet (Event Viewer > Application)"
                    }
                }
                if ($Component -ne 'cp') {
                    $dpConf = Join-Path $ConfDir 'toutwaf-dp.yaml'
                    & $DpExe --config $dpConf check-config
                    if ($LASTEXITCODE -ne 0) { throw 'toutwaf-dp check-config failed; service not started' }
                    Start-Service -Name $DpService
                    if (-not (Wait-DpHealthy)) { Restore-Dp; throw (T 'w_rollback') }
                }
            }
        } else { Write-Out '  services installed but not started (-NoStart)' }
        # the new binaries are in place: remember their version and build (the binary's own when it names one, else what the archive / channel says)
        $recExe = if ($Component -ne 'dp' -and (Test-Path $CpExe)) { $CpExe } else { $DpExe }
        $recV = Get-InstalledVersion $recExe; $recB = Get-InstalledBuild $recExe
        if (-not $recV) { $recV = if ($script:Rel.Version -and $script:Rel.Version -ne 'local') { $script:Rel.Version } else { $script:Rel.ArchiveVersion } }
        if (-not $recB) { $recB = $newBuild }
        Save-InstalledRecord $recV $recB
        return @{ OldDp = $oldDp }
    }
    finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------------------------------------ prerequisites of the machine
# Said BEFORE anything is changed, each problem with its cause and its fix (the same words and thresholds as install.sh and as the link command the
# console gives for a web server). Only a disk that is really full stops the installation (exit 4; $env:TOUTWAF_SKIP_PREREQ=1 goes on anyway): an
# unresolvable name or a wrong clock is a warning. Windows is never updated from here (an update of Windows restarts the machine). Read-only.
function Get-PrereqHost([string]$url) {
    if (-not $url) { return '' }
    try { $u = [Uri]$url } catch { return '' }
    if (-not $u.IsAbsoluteUri -or $u.IsFile -or $u.HostNameType -ne [UriHostNameType]::Dns) { return '' }
    return $u.DnsSafeHost
}
function Get-PrereqFindings {
    # returns objects with Level (refuse | warn), Cause and Action
    $out = New-Object System.Collections.ArrayList
    $refuse = if ($env:TOUTWAF_SKIP_PREREQ -eq '1') { 'warn' } else { 'refuse' }
    # 1. disk space where the programs, the data and the download go (MIN: below it the installation could not finish; WARN: comfortable)
    $seen = @{}
    foreach ($e in @(@($InstallDir, 300, 1024), @($DataRoot, 300, 1024), @([IO.Path]::GetTempPath(), 100, 300))) {
        try {
            $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$e[0]))
            if (-not $root -or $root.StartsWith('\\') -or $seen.ContainsKey($root)) { continue }
            $seen[$root] = $true
            $mb = [int]((New-Object IO.DriveInfo -ArgumentList $root).AvailableFreeSpace / 1MB)
            if ($mb -lt $e[1]) { [void]$out.Add(@{ Level = $refuse; Cause = (T 'pr_disk_full' @($mb, $root, $e[1])); Action = (T 'pr_disk_full_w_a') }) }
            elseif ($mb -lt $e[2]) { [void]$out.Add(@{ Level = 'warn'; Cause = (T 'pr_disk_low' @($mb, $root, $e[2])); Action = (T 'pr_disk_low_a') }) }
        } catch { $null = $_ }
    }
    # 2. DNS and 3. the clock, for the places the installation downloads from (nothing to resolve when it installs from a local archive)
    $hosts = New-Object System.Collections.ArrayList
    if (-not $ZipPath) {
        $mirror = if ($BaseUrl) { $BaseUrl } else { $env:TOUTWAF_BASE_URL }
        if ($mirror) { [void]$hosts.Add((Get-PrereqHost $mirror)) }
        else { [void]$hosts.Add((Get-PrereqHost $script:SrcPrimary)); [void]$hosts.Add((Get-PrereqHost $script:SrcFallback)) }
    }
    [void]$hosts.Add((Get-PrereqHost $CpUrl))
    $done = @{}; $first = ''
    foreach ($h in $hosts) {
        if (-not $h -or $done.ContainsKey($h)) { continue }
        $done[$h] = $true
        try { [void][System.Net.Dns]::GetHostAddresses($h); if (-not $first -and -not $ZipPath) { $first = $h } }
        catch { [void]$out.Add(@{ Level = 'warn'; Cause = (T 'pr_dns' @($h)); Action = (T 'pr_dns_w_a') }) }
    }
    if ($first) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Method Head -Uri "https://$first/" -TimeoutSec 10
            $d = [DateTimeOffset]::Parse([string]$r.Headers['Date'], [Globalization.CultureInfo]::InvariantCulture)
            $skew = [int][Math]::Abs(([DateTimeOffset]::UtcNow - $d).TotalSeconds)
            if ($skew -gt 300) { [void]$out.Add(@{ Level = 'warn'; Cause = (T 'pr_clock' @($skew)); Action = (T 'pr_clock_w_a') }) }
        } catch { $null = $_ }
    }
    return $out
}
function Test-Prerequisites {
    # prints the findings; $false only for a full disk
    $f = @(Get-PrereqFindings)
    if ($f.Count -eq 0) { return $true }
    $stop = (@($f | Where-Object { $_.Level -eq 'refuse' })).Count -gt 0
    if ($Quiet -and -not $stop) { foreach ($x in $f) { Write-InstallLog ('[prereq] ' + $x.Cause) }; return $true }
    Write-Host ''
    Write-Host ('  ' + (Paint $script:B (T 'pf_title')))
    foreach ($x in $f) {
        if ($x.Level -eq 'refuse') { $lab = T 'pf_l_refuse'; $col = $script:Red } else { $lab = T 'pf_l_warn'; $col = $script:Ylw }
        Write-Host ('  {0} {1}' -f (Paint $col "[$lab]"), $x.Cause)
        Write-Host ('      ' + $x.Action)
        Write-InstallLog ('[prereq] ' + $x.Cause)
    }
    if ($stop) { Write-Host ''; Write-Host ('  ' + (T 'pf_refused')); Write-Host '' }
    return (-not $stop)
}

# ------------------------------------------------------------------------------------------------ interactive menu / options
function Show-Menu {
    Write-Banner
    $s = Get-InstallState
    $st = ''
    if ($s.Dp) { $st += "toutwaf-dp $(Get-InstalledLabel $DpExe)  " }
    if ($s.Cp) { $st += "toutwaf-cp $(Get-InstalledLabel $CpExe)  " }
    if ($st) { Write-Out ('  ' + (T 'state_installed' @($st))) } else { Write-Out ('  ' + (T 'state_none')) }
    Write-Host ''
    Box-Top (T 'menu_title')
    $items = @(@('opt_install', 'opt_install_d'), @('opt_cp', 'opt_cp_d'), @('opt_dp', 'opt_dp_d'), @('opt_update', 'opt_update_d'), @('opt_uninstall', 'opt_uninstall_d'), @('opt_status', 'opt_status_d'), @('opt_links', 'opt_links_d'))
    for ($i = 0; $i -lt $items.Count; $i++) {
        Box-Line ('{0}{1}[{2}]{3} {0}{4}{3}' -f $script:B, $script:Vio, ($i + 1), $script:R, (T $items[$i][0]))
        Box-Line ('    {0}{1}{2}' -f $script:D, (T $items[$i][1]), $script:R)
    }
    Box-Line ('{0}{1}[q]{2} {3}' -f $script:B, $script:Vio, $script:R, (T 'opt_quit'))
    Box-Bottom
    while ($true) {
        $c = Read-Answer (T 'choice') ''
        switch ($c) {
            '1' { return @{ Action = 'install'; Component = 'all' } }
            '2' { return @{ Action = 'install'; Component = 'cp' } }
            '3' { return @{ Action = 'install'; Component = 'dp' } }
            '4' { return @{ Action = 'update'; Component = '' } }
            '5' { return @{ Action = 'uninstall'; Component = '' } }
            '6' { return @{ Action = 'status'; Component = '' } }
            '7' { return @{ Action = 'links'; Component = '' } }
            { $_ -in @('q', 'Q') } { return $null }
            default { Write-Out ('  ' + (Paint $script:Red (T 'invalid_choice'))) }
        }
    }
}
function Read-InstallOptions {
    Box-Top (T 'cfg_title'); Box-Bottom
    if ($Component -eq 'dp' -and -not $CpUrl) { $script:CpUrl = Read-Answer (T 'q_cp_url') '' }
    if ($CpUrl -and -not ($NodeToken -or $EnrollToken)) { $script:EnrollToken = Read-Answer (T 'q_token') '' -Secret }
    if ($CpUrl -and $CpUrl -match '^https://' -and -not $CpCa) { $script:CpCa = Read-Answer (T 'q_cp_ca') '' }
    if ($Component -ne 'dp') { $script:CpPort = [int](Read-Answer (T 'q_cp_port') "$CpPort"); $script:PublicHost = Read-Answer (T 'q_public_host') $PublicHost }
    if ($Component -ne 'cp') { $script:HttpPort = [int](Read-Answer (T 'q_http_port') "$HttpPort"); $script:HttpsPort = [int](Read-Answer (T 'q_https_port') "$HttpsPort") }
    if (Read-YesNo (T 'q_firewall') $true) { $script:OpenFirewall = [switch]$true } else { $script:NoFirewall = [switch]$true }
    if (-not (Read-YesNo (T 'q_boot') $true)) { $script:NoEnable = [switch]$true }
    if (-not $ZipPath) { $ch = Read-Answer (T 'q_channel') $script:Channel; if ($ch -in @('stable', 'dev', 'beta')) { $script:Channel = $(if ($ch -eq 'beta') { 'dev' } else { $ch }) } }
    $script:InstallDir = Read-Answer (T 'q_bindir') $InstallDir
    $script:DpExe = Join-Path $script:InstallDir 'toutwaf-dp.exe'
    $script:CpExe = Join-Path $script:InstallDir 'toutwaf-cp.exe'
    if (-not (Read-YesNo (T 'q_confirm') $true)) { Write-Out ('  ' + (T 'aborted')); return $false }
    return $true
}

# ------------------------------------------------------------------------------------------------ main
function Invoke-Main {
    Initialize-Ui
    $compat = Get-WindowsCompat
    if ($CheckCompat) {
        Write-WindowsCompat $compat
        if ($compat.Status -eq 'unsupported') { return 3 }
        return 0
    }
    if (-not (Test-Admin)) { throw 'Run this script from an elevated PowerShell (Run as Administrator).' }
    Resolve-Channel
    $action = ''
    foreach ($a in @('Install', 'Update', 'Uninstall', 'Status', 'Links')) { if ($script:Bound.ContainsKey($a) -and (Get-Variable $a -ValueOnly)) { $action = $a.ToLower() } }
    if (-not $action) {
        if ($script:Bound.Count -eq 0 -and (Test-Interactive)) {
            $m = Show-Menu
            if (-not $m) { return 0 }
            $action = $m.Action
            if ($m.Component) { $script:Component = $m.Component }
        } else { $action = 'install' }
    }
    $startLog = {
        New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
        $script:LogReady = $true
        Write-InstallLog ('#### {0} toutwaf install.ps1 v{1}' -f (Get-Date).ToUniversalTime().ToString('s'), $script:InstallerVersion)
    }
    switch ($action) {
        'status' { & $startLog; return (Invoke-Status) }
        'links' { & $startLog; return (Invoke-Links) }
        'uninstall' { & $startLog; Invoke-Uninstall; return 0 }
    }
    # an unsupported Windows version / architecture stops here (exit 3), before anything is changed
    if ($compat.Status -eq 'unsupported') {
        if ($SkipOsCheck) {
            Write-Warn (T 'cp_w_skip'); foreach ($r in $compat.Reasons) { Write-Warn "  - $r" }
            $script:CompatLine = ((T 'cp_w_skip') + ' ' + ($compat.Reasons -join ' '))
        } else {
            Write-WindowsCompat $compat
            Write-Host ('  ' + (T 'cp_nochange'))
            Write-Host ('  ' + ((T 'cp_override') -replace '--skip-os-check', '-SkipOsCheck'))
            Write-Host ''
            return 3
        }
    } else { $script:CompatLine = (T 'cp_ok' @($compat.Label, (T "cp_$($compat.Status)"))) }
    & $startLog
    $state = Get-InstallState
    if ($action -eq 'update') {
        if (-not $state.Dp -and -not $state.Cp) { throw (T 'not_installed') }
        Set-ComponentFromInstalled
        Import-ExistingPorts
        if ($script:Bound.Count -eq 0 -and (Test-Interactive)) { $ch = Read-Answer (T 'q_channel') $script:Channel; if ($ch -in @('stable', 'dev', 'beta')) { $script:Channel = $(if ($ch -eq 'beta') { 'dev' } else { $ch }) } }
    } else {
        if ($state.Cp) { Import-ExistingPorts }
        Write-Banner
        if (Test-Interactive) { if (-not (Read-InstallOptions)) { return 0 } }
    }
    if (($EnrollToken -or $NodeToken) -and -not $CpUrl) { throw (T 'need_cp') }
    Write-Banner
    Write-Out ('  {0}os=windows arch={1} component={2} channel={3}{4}' -f $script:D, (Get-Arch), $Component, $script:Channel, $script:R)
    if ($compat.Status -ne 'unsupported') { Write-Out ('  {0}{1}{2} {3}' -f $script:Grn, $script:OkM, $script:R, $script:CompatLine) }
    # disk space, DNS and the clock, with the fix of each problem: only a full disk stops (exit 4; $env:TOUTWAF_SKIP_PREREQ=1 goes on anyway)
    if (-not $DryRun -and -not (Test-Prerequisites)) { return 4 }
    $pub = ''
    if ($Component -ne 'dp') { $pub = Get-PublicIp }
    if ($Component -ne 'dp') { Write-Out ('  {0} {1}' -f $script:Bul, (T $(if (Test-NoTelemetry) { 'tele_off' } else { 'tele_on' }))) }   # what is shared with the publisher space, said before anything is installed
    $res = Invoke-InstallFlow $action
    Write-Host ''
    if ($null -eq $res) { return 0 }
    $newDp = Get-InstalledLabel $DpExe; if ($newDp -eq '?') { $newDp = '' }
    $tail = ''
    if ($newDp) { $tail = "  toutwaf-dp $newDp"; if ($res.OldDp) { $tail += " (was $($res.OldDp))" } }
    Write-Out ('  {0}{1}{2} {3}{4}' -f $script:Grn, $script:OkM, $script:R, (T 'done'), $tail)
    Write-ExtrasReport
    if ($script:Warnings.Count -gt 0 -and $script:Color -and -not $Quiet) { foreach ($w in $script:Warnings) { Write-Host ('  {0}{1}{2} {3}' -f $script:Ylw, $script:WrM, $script:R, $w) } }
    if ($Component -ne 'dp' -and -not $script:PanelTried) { [void](Invoke-CpLinks) }
    Show-Summary $pub
    if ($Component -ne 'cp') {
        Write-Out ('  {0}data plane: Get-Service {1}   config: {2}   health: Invoke-RestMethod http://127.0.0.1:9101/healthz{3}' -f $script:D, $DpService, (Join-Path $ConfDir 'toutwaf-dp.yaml'), $script:R)
    }
    Write-Out ('  {0}logs (services write to files, the service manager discards stdout): {1}{2}' -f $script:D, $LogDir, $script:R)
    Save-SummaryFile $pub
    return 0
}

if ($env:TOUTWAF_PS_NOMAIN -ne '1') {
    try { $code = Invoke-Main; if ($code -is [int] -and $code -ne 0) { exit $code } }
    catch { Stop-Spin; Write-Host ('{0}{1} {2}{3}' -f $script:Red, $script:ErM, $_.Exception.Message, $script:R); exit 1 }
}
