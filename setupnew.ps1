<#
Windows hardening + Chocolatey apps + Dark Mode + Edge policies
Run once (it will auto-elevate to Admin).
#>

# ----------------------------
# 1) Admin check / auto-elevate
# ----------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy Bypass",
        "-File `"$PSCommandPath`""
    )
    exit
}

$ErrorActionPreference = "Continue"

Write-Host "`n=== Starting setup (Hardening + Apps + UI + Edge) ===`n" -ForegroundColor Cyan


# ----------------------------
# 2) Basic hardening
#    - Disable SSL 2.0/3.0 and TLS 1.0/1.1
#    - Ensure TLS 1.2 and TLS 1.3 enabled
#    - Disable SMBv1
#    - Disable NetBIOS
#    - Disable NTLMv1
#    - Disable Guest account
#    - Disable WDigest credential caching
# ----------------------------

Write-Host "Hardening: disabling old SSL/TLS..." -ForegroundColor Yellow

$disableProtocols = @("SSL 2.0", "SSL 3.0", "TLS 1.0", "TLS 1.1")
$types = @("Client", "Server")

foreach ($p in $disableProtocols) {
    foreach ($t in $types) {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$p\$t"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name "Enabled"           -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path $path -Name "DisabledByDefault" -PropertyType DWord -Value 1 -Force | Out-Null
    }
}

Write-Host "Hardening: ensuring TLS 1.2 and TLS 1.3 are enabled..." -ForegroundColor Yellow
foreach ($ver in @("TLS 1.2", "TLS 1.3")) {
    foreach ($t in $types) {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$ver\$t"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name "Enabled"           -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path $path -Name "DisabledByDefault" -PropertyType DWord -Value 0 -Force | Out-Null
    }
}

Write-Host "Hardening: disabling SMBv1..." -ForegroundColor Yellow
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -Confirm:$false | Out-Null

Write-Host "Hardening: disabling NetBIOS..." -ForegroundColor Yellow
$netbt = "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces"
if (Test-Path $netbt) {
    Get-ChildItem $netbt | ForEach-Object {
        New-ItemProperty -Path $_.PSPath -Name "NetbiosOptions" -PropertyType DWord -Value 2 -Force | Out-Null
    }
}

Write-Host "Hardening: disabling NTLMv1 (LmCompatibilityLevel=5)..." -ForegroundColor Yellow
$lsaPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
New-ItemProperty -Path $lsaPath -Name "LmCompatibilityLevel" -PropertyType DWord -Value 5 -Force | Out-Null

Write-Host "Hardening: disabling Guest account..." -ForegroundColor Yellow
net user Guest /active:no 2>$null

Write-Host "Hardening: disabling WDigest credential caching..." -ForegroundColor Yellow
$wdigestPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest"
if (-not (Test-Path $wdigestPath)) { New-Item -Path $wdigestPath -Force | Out-Null }
New-ItemProperty -Path $wdigestPath -Name "UseLogonCredential" -PropertyType DWord -Value 0 -Force | Out-Null


# ----------------------------
# 3) Windows Dark Mode
# ----------------------------
Write-Host "UI: enabling Dark Mode..." -ForegroundColor Yellow

$personalize = "Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

# Current user
$hkcu = "HKCU:\$personalize"
if (-not (Test-Path $hkcu)) { New-Item -Path $hkcu -Force | Out-Null }
New-ItemProperty -Path $hkcu -Name "AppsUseLightTheme"    -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $hkcu -Name "SystemUsesLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null

# Default profile (new users)
$hkdef = "Registry::HKEY_USERS\.DEFAULT\$personalize"
if (-not (Test-Path $hkdef)) { New-Item -Path $hkdef -Force | Out-Null }
New-ItemProperty -Path $hkdef -Name "AppsUseLightTheme"    -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $hkdef -Name "SystemUsesLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null


# ----------------------------
# 4) Microsoft Edge policies
#    - Disable first run, nags, content
#    - Set Google as default search engine
# ----------------------------
Write-Host "Edge: applying policies (no first-run, Google search)..." -ForegroundColor Yellow

$edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
New-Item -Path $edgePolicy -Force | Out-Null

New-ItemProperty -Path $edgePolicy -Name "HideFirstRunExperience"        -PropertyType DWord  -Value 1          -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "BrowserSignin"                 -PropertyType DWord  -Value 0          -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "NewTabPageContentEnabled"      -PropertyType DWord  -Value 0          -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "PromotionalTabsEnabled"        -PropertyType DWord  -Value 0          -Force | Out-Null

New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderEnabled"  -PropertyType DWord  -Value 1          -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderName"     -PropertyType String -Value "Google"   -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderKeyword"  -PropertyType String -Value "google.com" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderSearchURL" -PropertyType String -Value "https://www.google.com/search?q={searchTerms}" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderSuggestURL" -PropertyType String -Value "https://www.google.com/complete/search?output=chrome&q={searchTerms}" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderIconURL"  -PropertyType String -Value "https://www.google.com/favicon.ico" -Force | Out-Null


# ----------------------------
# 5) Install Chocolatey (if missing)
# ----------------------------
Write-Host "Chocolatey: checking/installing..." -ForegroundColor Yellow

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
}

# Refresh PATH so choco is available in this session
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")

# Suppress interactive confirmation prompts (does NOT affect hash verification)
choco feature enable -n allowGlobalConfirmation | Out-Null


# ----------------------------
# 6) Install apps via Chocolatey
# ----------------------------
Write-Host "Apps: installing via Chocolatey..." -ForegroundColor Yellow

$packages = @(
    "firefox",
    "warp",
    "winfsp",
    "rclone",
    "qbittorrent",
    "7zip",
    "git",
    "vscode"
)

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Warning "Chocolatey not available - skipping package install."
} else {
    choco install $packages -y --no-progress
}


# ----------------------------
# 7) Configure qBittorrent (write config before first launch)
# ----------------------------
Write-Host "Config: writing qBittorrent settings..." -ForegroundColor Yellow

$qbConfigDir  = "$env:APPDATA\qBittorrent"
$qbConfigFile = "$qbConfigDir\qBittorrent.ini"

if (-not (Test-Path $qbConfigDir)) {
    New-Item -Path $qbConfigDir -ItemType Directory -Force | Out-Null
}

if (Test-Path $qbConfigFile) {
    Copy-Item $qbConfigFile "$qbConfigFile.bak" -Force
    Write-Host "  Existing config backed up to qBittorrent.ini.bak" -ForegroundColor DarkGray
}

# NOTE: If you route traffic through a VPN, set Session\Interface to your VPN
# adapter name (e.g. "ProtonVPN") to bind qBittorrent to that interface only.

$qbConfig = @"
[AddNewTorrentDialog]
SavePathHistory=$($env:USERPROFILE -replace '\\', '\\\\')\\Downloads\\z
DialogSize=@Size(900 680)
DownloadPathHistory=$($env:USERPROFILE -replace '\\', '\\\\')\\Downloads\\temp
RememberLastSavePath=true

[LegalNotice]
Accepted=true

[Application]
FileLogger\AgeType=1
GUI\Notifications\TorrentAdded=false
FileLogger\DeleteOld=true
FileLogger\Age=1
FileLogger\Path=$($env:USERPROFILE -replace '\\', '\\\\')\\AppData\\Local\\qBittorrent\\logs
FileLogger\MaxSizeBytes=66560
FileLogger\Backup=true
FileLogger\Enabled=true

[BitTorrent]
Session\QueueingSystemEnabled=false
Session\ShareLimitAction=Remove
Session\TempPathEnabled=true
Session\GlobalUPSpeedLimit=0
Session\GlobalMaxRatio=0
Session\DefaultSavePath=$($env:USERPROFILE -replace '\\', '\\\\')\\Downloads\\z
Session\Port=35196
Session\SSL\Port=60785
Session\StartPaused=false

[GUI]
Log\Enabled=false
DownloadTrackerFavicon=false
MainWindow\FiltersSidebarWidth=163

[Meta]
MigrationVersion=8

[Preferences]
General\CloseToTrayNotified=true
General\Locale=en

[Core]
AutoDeleteAddedTorrentFile=IfAdded

[RSS]
AutoDownloader\DownloadRepacks=true
AutoDownloader\SmartEpisodeFilter=s(\\d+)e(\\d+), (\\d+)x(\\d+), "(\\d{4}[.\\-]\\d{1,2}[.\\-]\\d{1,2})", "(\\d{1,2}[.\\-]\\d{1,2}[.\\-]\\d{4})"

[TransferList]
SubSortOrder=1
SubSortColumn=0
"@

Set-Content -Path $qbConfigFile -Value $qbConfig -Encoding UTF8
Write-Host "qBittorrent config written to: $qbConfigFile" -ForegroundColor Green


# ----------------------------
# 8) Install uv and Python
# ----------------------------
Write-Host "Apps: installing uv (Python manager)..." -ForegroundColor Yellow

try {
    Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
} catch {
    Write-Warning "uv installation failed: $_"
}

Write-Host "Refreshing PATH..."
if (Test-Path "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1") {
    Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1" -Force -ErrorAction SilentlyContinue
    refreshenv
}

$env:Path =
    [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
    [Environment]::GetEnvironmentVariable("Path","User")

# Pin a version for reproducibility if needed, e.g.: uv python install 3.12
uv python install


Write-Host "`n=== Done. A restart may be required for some changes. ===`n" -ForegroundColor Green
