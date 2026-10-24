#Requires -Version 5.1
<#
.SYNOPSIS
  ToutWAF Backup installer for Windows (server or client role). Run in an elevated PowerShell. Idempotent: run again to upgrade.

.DESCRIPTION
  Downloads channel.json, the signed SHA256SUMS and the archive; VERIFIES the Ed25519 signature of SHA256SUMS with the public key
  baked into this script (pure PowerShell implementation of RFC 8032 verification, no external tool), then the SHA-256 of the archive.
  Installs toutwaf-backup.exe, and for the server role: the state directory (restricted to SYSTEM and Administrators), the first
  configuration and admin token, the Windows service (native service wrapper in the binary) and a firewall rule (Domain and Private
  profiles only).

  STATUS: NOT TESTED ON A REAL WINDOWS MACHINE in this release (this script was written on Linux; see docs/INSTALL-WINDOWS.md,
  "What was tested"). The signature algorithm was validated in Python against RFC 8032 and against real release signatures; the PowerShell
  port follows it line by line.

.EXAMPLE
  .\install.ps1 -Role server -ExternalUrl https://backup.example.net:8007 -Datastore main=D:\Backups\main -Start
  .\install.ps1 -Role client
  .\install.ps1 -Role server -Uninstall
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('server', 'client')][string]$Role,
  [string]$Channel = '',
  [string]$BaseUrl = '',
  [string]$Version = '',
  [string]$InstallDir = (Join-Path $env:ProgramFiles 'ToutWAF Backup'),
  [string]$StateDir = (Join-Path $env:ProgramData 'toutwaf-backup\server'),
  [string]$Listen = ':8007',
  [string]$ExternalUrl = '',
  [string]$Datastore = '',
  [switch]$NoInit,
  [switch]$Start,
  [switch]$NoFirewall,
  [switch]$Uninstall,
  [switch]$Purge,
  [switch]$Force,
  [switch]$Yes,
  [string]$PubKey = '',
  [string]$PubKeyFile = ''
)
$ErrorActionPreference = 'Stop'
$InstallerVersion = 1
$DefaultChannel = 'dev'
$DefaultBaseUrl = 'https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/toutwaf-backup'
$FallbackBaseUrl = 'https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup'
$ReleasePubKey = 'V7tJBQsSrIsDTGIqlFhJZ8q4t/Fc8iNvg/cKkfRDATA='

function Say($m) { Write-Host $m }
Write-Warning 'This installer and the Windows-specific parts of ToutWAF Backup (service, VSS, NTFS ACLs, long paths) have NOT been tested on a real Windows machine in this release. Try it on a non-critical machine first (docs/INSTALL-WINDOWS.md).'
function Fail($m) { Write-Error "install.ps1: $m"; exit 1 }

if (-not $Channel) { $Channel = $DefaultChannel }
$BaseExplicit = $true
if (-not $BaseUrl -and $env:TOUTWAF_BACKUP_BASE_URL) { $BaseUrl = $env:TOUTWAF_BACKUP_BASE_URL }
if (-not $BaseUrl) { $BaseUrl = $DefaultBaseUrl; $BaseExplicit = $false }
if ($PubKeyFile) { if (-not (Test-Path $PubKeyFile)) { Fail "cannot read $PubKeyFile" }; $PubKey = (Get-Content $PubKeyFile -Raw).Trim() }
if ($PubKey) { Write-Warning 'using the public key given with -PubKey instead of the one baked into this script'; $ReleasePubKey = $PubKey }
if ($ReleasePubKey -notmatch '^[A-Za-z0-9+/]{43}=$') { Fail 'this installer has no valid release public key (it is baked in by tools/build-release.sh; use the install.ps1 served with the release)' }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail 'run this script in an elevated PowerShell (Run as administrator)' }
if ($BaseUrl -notmatch '^(https://|http://127\.0\.0\.1|http://localhost)') { Fail '-BaseUrl must be https:// (http only for localhost)' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- a backup SERVER must not live on a machine that runs ToutWAF ---------------------------------------------------------------------
if ($Role -eq 'server' -and -not $Uninstall -and $env:TWB_ALLOW_SAME_HOST -ne '1') {
  $found = @()
  foreach ($p in @((Join-Path $env:ProgramFiles 'ToutWAF'), (Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }) 'ToutWAF'))) { if (Test-Path $p) { $found += $p } }
  foreach ($svcName in 'toutwaf-cp', 'toutwaf-dp') { if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) { $found += "service:$svcName" } }
  foreach ($exeName in 'toutwaf-cp.exe', 'toutwaf-dp.exe', 'toutwafctl.exe') { $c = Get-Command $exeName -ErrorAction SilentlyContinue; if ($c) { $found += $c.Source } }
  foreach ($port in 9443, 9444) { if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { $found += "listening-port:$port" } }
  if ($found.Count -gt 0) {
    $list = $found -join ' '
    [Console]::Error.WriteLine("install.ps1: REFUSED / REFUS`n  EN: ToutWAF is installed on this machine (found: $list).`n      The ToutWAF Backup SERVER must run on a DIFFERENT machine: a backup stored on the machine it protects does not survive the loss of`n      that machine (disk failure, ransomware, fire, theft). Install the server on another host. The backup CLIENT (-Role client) can be installed here.`n  FR: ToutWAF est installé sur cette machine (trouvé : $list).`n      Le SERVEUR ToutWAF Backup doit tourner sur une AUTRE machine : une sauvegarde stockée sur la machine qu'elle protège ne survit pas`n      à la perte de cette machine (panne de disque, rançongiciel, incendie, vol). Installez le serveur sur un autre hôte.`n      Le CLIENT de sauvegarde (-Role client) peut être installé ici.")
    exit 3
  }
}

$Exe = Join-Path $InstallDir 'toutwaf-backup.exe'
$ServiceName = 'toutwaf-backup'
$Port = ($Listen -split ':')[-1]; if (-not $Port) { $Port = '8007' }

# ---- uninstall ----------------------------------------------------------------------------------------------------------------
if ($Uninstall) {
  if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $ServiceName | Out-Null
    Say "Service $ServiceName removed."
  }
  Remove-NetFirewallRule -DisplayName 'ToutWAF Backup server' -ErrorAction SilentlyContinue
  if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir; Say "Removed $InstallDir." }
  if ($Purge) {
    if (-not $Yes) { $a = Read-Host "PURGE deletes $StateDir (including any datastore inside it). Type YES to continue"; if ($a -ne 'YES') { Fail 'aborted' } }
    if (Test-Path $StateDir) { Remove-Item -Recurse -Force $StateDir }
    Say 'State removed.'
  } else { Say "State ($StateDir) is kept. Add -Purge to delete it." }
  exit 0
}

# ---- Ed25519 verification (RFC 8032), pure PowerShell -----------------------------------------------------------------------------
Add-Type -AssemblyName System.Numerics
$script:P = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]2, 255) - [System.Numerics.BigInteger]19
$script:L = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]2, 252) + [System.Numerics.BigInteger]::Parse('27742317777372353535851937790883648493')

function BI-FromLE([byte[]]$b) { $t = New-Object byte[] ($b.Length + 1); [Array]::Copy($b, $t, $b.Length); return New-Object System.Numerics.BigInteger (, $t) }
function BI-Mod([System.Numerics.BigInteger]$a) { $r = [System.Numerics.BigInteger]::Remainder($a, $script:P); if ($r.Sign -lt 0) { $r = $r + $script:P }; return $r }
function BI-Inv([System.Numerics.BigInteger]$a) { return [System.Numerics.BigInteger]::ModPow($a, $script:P - [System.Numerics.BigInteger]2, $script:P) }
function BI-ToLE32([System.Numerics.BigInteger]$n) { $b = $n.ToByteArray(); $o = New-Object byte[] 32; $c = [Math]::Min($b.Length, 32); [Array]::Copy($b, $o, $c); return $o }

$script:D = BI-Mod ([System.Numerics.BigInteger]::Negate([System.Numerics.BigInteger]121665) * (BI-Inv ([System.Numerics.BigInteger]121666)))
$script:SqrtM1 = [System.Numerics.BigInteger]::ModPow([System.Numerics.BigInteger]2, ($script:P - [System.Numerics.BigInteger]1) / [System.Numerics.BigInteger]4, $script:P)

function Ed-Decode([byte[]]$b) {
  $n = BI-FromLE $b
  $sign = [int](($b[31] -shr 7) -band 1)
  $y = $n
  if ($sign -eq 1) { $y = $n - [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]2, 255) }
  if ($y -ge $script:P) { return $null }
  $y2 = BI-Mod ($y * $y)
  $x2 = BI-Mod (($y2 - [System.Numerics.BigInteger]1) * (BI-Inv (BI-Mod ($script:D * $y2 + [System.Numerics.BigInteger]1))))
  $x = [System.Numerics.BigInteger]::ModPow($x2, ($script:P + [System.Numerics.BigInteger]3) / [System.Numerics.BigInteger]8, $script:P)
  if ((BI-Mod ($x * $x - $x2)).Sign -ne 0) { $x = BI-Mod ($x * $script:SqrtM1) }
  if ((BI-Mod ($x * $x - $x2)).Sign -ne 0) { return $null }
  if ($x.IsZero -and $sign -eq 1) { return $null }
  if ([int]($x % [System.Numerics.BigInteger]2) -ne $sign) { $x = $script:P - $x }
  return @($x, $y, [System.Numerics.BigInteger]1, (BI-Mod ($x * $y)))
}

function Ed-Add($p1, $q1) {
  $a = BI-Mod (($p1[1] - $p1[0]) * ($q1[1] - $q1[0]))
  $b = BI-Mod (($p1[1] + $p1[0]) * ($q1[1] + $q1[0]))
  $c = BI-Mod ([System.Numerics.BigInteger]2 * $p1[3] * $q1[3] * $script:D)
  $d = BI-Mod ([System.Numerics.BigInteger]2 * $p1[2] * $q1[2])
  $e = $b - $a; $f = $d - $c; $g = $d + $c; $h = $b + $a
  return @((BI-Mod ($e * $f)), (BI-Mod ($g * $h)), (BI-Mod ($f * $g)), (BI-Mod ($e * $h)))
}

function Ed-Mul([System.Numerics.BigInteger]$s, $pt) {
  $q = @([System.Numerics.BigInteger]0, [System.Numerics.BigInteger]1, [System.Numerics.BigInteger]1, [System.Numerics.BigInteger]0)
  $bytes = $s.ToByteArray()
  $nbits = $bytes.Length * 8
  for ($i = 0; $i -lt $nbits; $i++) {
    if ((($bytes[$i -shr 3] -shr ($i -band 7)) -band 1) -eq 1) { $q = Ed-Add $q $pt }
    $pt = Ed-Add $pt $pt
  }
  return $q
}

function Ed-Equal($p1, $q1) {
  if ((BI-Mod ($p1[0] * $q1[2] - $q1[0] * $p1[2])).Sign -ne 0) { return $false }
  if ((BI-Mod ($p1[1] * $q1[2] - $q1[1] * $p1[2])).Sign -ne 0) { return $false }
  return $true
}

function Ed25519-Verify([byte[]]$pub, [byte[]]$msg, [byte[]]$sig) {
  if ($pub.Length -ne 32 -or $sig.Length -ne 64) { return $false }
  $rBytes = New-Object byte[] 32; [Array]::Copy($sig, 0, $rBytes, 0, 32)
  $sBytes = New-Object byte[] 32; [Array]::Copy($sig, 32, $sBytes, 0, 32)
  $R = Ed-Decode $rBytes; $A = Ed-Decode $pub
  if ($null -eq $R -or $null -eq $A) { return $false }
  $S = BI-FromLE $sBytes
  if ($S -ge $script:L) { return $false }
  $by = BI-Mod ([System.Numerics.BigInteger]4 * (BI-Inv ([System.Numerics.BigInteger]5)))
  $B = Ed-Decode (BI-ToLE32 $by)
  $sha = [System.Security.Cryptography.SHA512]::Create()
  $buf = New-Object byte[] (64 + $msg.Length)
  [Array]::Copy($rBytes, 0, $buf, 0, 32); [Array]::Copy($pub, 0, $buf, 32, 32); [Array]::Copy($msg, 0, $buf, 64, $msg.Length)
  $hh = BI-FromLE ($sha.ComputeHash($buf))
  $h = [System.Numerics.BigInteger]::Remainder($hh, $script:L)
  $left = Ed-Mul $S $B
  $right = Ed-Add $R (Ed-Mul $h $A)
  return (Ed-Equal $left $right)
}

# ---- download and verify --------------------------------------------------------------------------------------------------------
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Fail "unsupported CPU $env:PROCESSOR_ARCHITECTURE (supported: AMD64)" }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('twb-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  try { Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/channel.json" -OutFile (Join-Path $tmp 'channel.json') }
  catch {
    if ($BaseExplicit) { Fail "cannot download $BaseUrl/channel.json" }
    Write-Warning "cannot reach $BaseUrl, trying $FallbackBaseUrl (the signature is verified the same way)"
    $BaseUrl = $FallbackBaseUrl
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/channel.json" -OutFile (Join-Path $tmp 'channel.json')
  }
  $ch = Get-Content (Join-Path $tmp 'channel.json') -Raw | ConvertFrom-Json
  if (-not $ch.version) { Fail 'the channel has no version yet (nothing is published)' }
  $want = if ($Version) { $Version } else { [string]$ch.version }
  if ($want -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') { Fail "bad version '$want'" }
  if (($ch.yanked -contains $want) -and -not $Force) { Fail "version $want was withdrawn (yanked); use -Force only if you know why" }

  $cur = ''
  if (Test-Path $Exe) { $o = & $Exe version 2>$null; if ($o -match '^toutwaf-backup (\S+)') { $cur = $Matches[1] } }
  if ($cur -eq $want -and -not $Force) {
    Say "toutwaf-backup $cur is already installed and up to date."
  } else {
    $asset = 'toutwaf-backup-windows-amd64.zip'
    $rel = "$BaseUrl/releases/$want"
    Say "Downloading toutwaf-backup $want ($Channel, windows/amd64)..."
    Invoke-WebRequest -UseBasicParsing -Uri "$rel/SHA256SUMS" -OutFile (Join-Path $tmp 'SHA256SUMS')
    Invoke-WebRequest -UseBasicParsing -Uri "$rel/SHA256SUMS.sig" -OutFile (Join-Path $tmp 'SHA256SUMS.sig')
    $sums = [IO.File]::ReadAllBytes((Join-Path $tmp 'SHA256SUMS'))
    $sigText = (Get-Content (Join-Path $tmp 'SHA256SUMS.sig') -Raw) -replace '\s', ''
    try { $sig = [Convert]::FromBase64String($sigText) } catch { Fail 'the signature file is not base64' }
    if (-not (Ed25519-Verify ([Convert]::FromBase64String($ReleasePubKey)) $sums $sig)) {
      Fail 'SIGNATURE VERIFICATION FAILED for SHA256SUMS: refusing to install. The download was tampered with, or this installer does not match the release.'
    }
    Say 'Signature of SHA256SUMS verified.'
    $line = (Get-Content (Join-Path $tmp 'SHA256SUMS')) | Where-Object { $_ -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($asset))$" } | Select-Object -First 1
    if (-not $line) { Fail "$asset is not listed in the signed SHA256SUMS" }
    $wantSum = ($line -split '\s+')[0]
    Invoke-WebRequest -UseBasicParsing -Uri "$rel/$asset" -OutFile (Join-Path $tmp $asset)
    $gotSum = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $asset)).Hash.ToLower()
    if ($gotSum -ne $wantSum) { Fail "SHA-256 of $asset does not match the signed list (expected $wantSum, got $gotSum): refusing to install" }
    Say 'SHA-256 of the archive verified.'
    Expand-Archive -Path (Join-Path $tmp $asset) -DestinationPath (Join-Path $tmp 'x') -Force
    $src = Join-Path $tmp 'x\toutwaf-backup-windows-amd64\toutwaf-backup.exe'
    if (-not (Test-Path $src)) { $src = (Get-ChildItem -Recurse -Path (Join-Path $tmp 'x') -Filter toutwaf-backup.exe | Select-Object -First 1).FullName }
    if (-not $src) { Fail 'the archive does not contain toutwaf-backup.exe' }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $wasRunning = $svc -and $svc.Status -eq 'Running'
    if ($wasRunning) { Stop-Service -Name $ServiceName -Force }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    if (Test-Path $Exe) { Copy-Item -Force $Exe "$Exe.prev" }
    Copy-Item -Force $src "$Exe.new"
    Move-Item -Force "$Exe.new" $Exe
    foreach ($f in 'LICENSE', 'README.md', 'CHANGELOG.md', 'THIRD-PARTY-NOTICES.md') {
      $p = Join-Path (Split-Path $src) $f; if (Test-Path $p) { Copy-Item -Force $p $InstallDir }
    }
    Say "Installed $Exe ($want)."
    if ($wasRunning) { Start-Service -Name $ServiceName; Say 'Service restarted on the new version.' }
  }

  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  if (($machinePath -split ';') -notcontains $InstallDir) {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$InstallDir", 'Machine')
    Say "Added $InstallDir to the system PATH (open a new terminal)."
  }

  if ($Role -eq 'client') {
    Say ''
    Say 'Client installed. Next steps:'
    Say '  toutwaf-backup client init --server https://BACKUP-SERVER:8007 --tofu --token <token> --datastore <name> --create-key'
    Say '  toutwaf-backup client backup --path C:\Data --id $env:COMPUTERNAME'
    Say '  toutwaf-backup client schedule --target windows --daily 02:30 --path C:\Data --out C:\ProgramData\toutwaf-backup   (then: schtasks /Create /TN ... /XML ...)'
    Say 'Keep the key file, its passphrase and the paper key OFF this machine too.'
    exit 0
  }

  # server role
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  & icacls.exe $StateDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
  $first = $false
  if (-not $NoInit -and -not (Test-Path (Join-Path $StateDir 'config.json'))) {
    $first = $true
    $initArgs = @('server', 'init', '--state', $StateDir, '--listen', $Listen)
    if ($ExternalUrl) { $initArgs += @('--external-url', $ExternalUrl) }
    if ($Datastore) { $initArgs += @('--datastore', $Datastore) }
    Say ''; Say 'First installation: creating the server configuration.'
    & $Exe @initArgs
    if ($LASTEXITCODE -ne 0) { Fail 'server init failed' }
    Say ''; Say 'WRITE DOWN the admin token and the certificate fingerprint above: the token is not shown again.'
  }
  if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
    & $Exe server service install --state $StateDir
    if ($LASTEXITCODE -ne 0) { Fail 'service installation failed' }
  }
  if (-not $NoFirewall) {
    if (-not (Get-NetFirewallRule -DisplayName 'ToutWAF Backup server' -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName 'ToutWAF Backup server' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Domain, Private | Out-Null
      Say "Firewall: inbound TCP $Port allowed on the Domain and Private profiles only. Restrict the remote addresses to your clients if you can."
    }
  }
  if ($Start) { Start-Service -Name $ServiceName; Say 'Service started.' } else { Say "Start it with: Start-Service $ServiceName" }
  if ($first) { Say "Then open https://THIS-HOST:$Port/ for the web interface." }
}
finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
