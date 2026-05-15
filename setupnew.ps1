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

# Use Continue so a single failure does not abort the whole script
$ErrorActionPreference = "Continue"

Write-Host "`n=== Starting setup (Hardening + Apps + UI + Edge) ===`n" -ForegroundColor Cyan

function Invoke-WithRetry {
    param([scriptblock]$ScriptBlock, [int]$MaxRetries = 3)
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try { & $ScriptBlock; return }
        catch { if ($i -eq $MaxRetries - 1) { throw }; Start-Sleep -Seconds 2 }
    }
}

# ----------------------------
# 2) Basic hardening
#    - Disable SSL 2.0/3.0 and TLS 1.0/1.1
#    - Ensure TLS 1.2 enabled
#    - Disable SMBv1
#    - Disable NetBIOS
# ----------------------------

Write-Host "Hardening: disabling old SSL/TLS..." -ForegroundColor Yellow

$disableProtocols = @("SSL 2.0", "SSL 3.0", "TLS 1.0", "TLS 1.1")
$types = @("Client", "Server")

foreach ($p in $disableProtocols) {
    foreach ($t in $types) {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$p\$t"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name "Enabled" -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path $path -Name "DisabledByDefault" -PropertyType DWord -Value 1 -Force | Out-Null
    }
}

Write-Host "Hardening: ensuring TLS 1.2 is enabled..." -ForegroundColor Yellow
foreach ($t in $types) {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\$t"
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name "Enabled" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $path -Name "DisabledByDefault" -PropertyType DWord -Value 0 -Force | Out-Null
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


# ----------------------------
# 3) Windows Dark Mode
# ----------------------------
Write-Host "UI: enabling Dark Mode..." -ForegroundColor Yellow

$personalize = "Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

# Current user
$hkcu = "HKCU:\$personalize"
if (-not (Test-Path $hkcu)) { New-Item -Path $hkcu -Force | Out-Null }
New-ItemProperty -Path $hkcu -Name "AppsUseLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $hkcu -Name "SystemUsesLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null

# Default profile (new users)
$hkdef = "Registry::HKEY_USERS\.DEFAULT\$personalize"
if (-not (Test-Path $hkdef)) { New-Item -Path $hkdef -Force | Out-Null }
New-ItemProperty -Path $hkdef -Name "AppsUseLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $hkdef -Name "SystemUsesLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null


# ----------------------------
# 4) Microsoft Edge policies
#    - Disable first run, nags, content
#    - Set Google as default search engine
# ----------------------------
Write-Host "Edge: applying policies (no first-run, Google search)..." -ForegroundColor Yellow

$edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
New-Item -Path $edgePolicy -Force | Out-Null

New-ItemProperty -Path $edgePolicy -Name "HideFirstRunExperience" -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "BrowserSignin" -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "NewTabPageContentEnabled" -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "PromotionalTabsEnabled" -PropertyType DWord -Value 0 -Force | Out-Null

# Default search = Google
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderEnabled" -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderName" -PropertyType String -Value "Google" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderKeyword" -PropertyType String -Value "google.com" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderSearchURL" -PropertyType String -Value "https://www.google.com/search?q={searchTerms}" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderSuggestURL" -PropertyType String -Value "https://www.google.com/complete/search?output=chrome&q={searchTerms}" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderIconURL" -PropertyType String -Value "https://www.google.com/favicon.ico" -Force | Out-Null


# ----------------------------
# 5) Install Chocolatey (if missing)
# ----------------------------
Write-Host "Chocolatey: checking/installing..." -ForegroundColor Yellow

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
}

# Refresh PATH for current session
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")


# ----------------------------
# 6) Install apps via Chocolatey
#    Note: Chrome is installed separately below via direct download
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
    Write-Warning "Chocolatey not available — skipping package install."
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

# If a config already exists, back it up first
if (Test-Path $qbConfigFile) {
    Copy-Item $qbConfigFile "$qbConfigFile.bak" -Force
    Write-Host "  Existing config backed up to qBittorrent.ini.bak" -ForegroundColor DarkGray
}

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
# 8) Install Google Chrome (direct download, installer kept on Desktop)
# ----------------------------
Write-Host "Apps: downloading and installing Google Chrome..." -ForegroundColor Yellow

# Resolve the Desktop path for the current user (works even if OneDrive has moved it)
$desktopPath = [Environment]::GetFolderPath("Desktop")
$chromeInstaller = "$desktopPath\ChromeStandaloneSetup64.exe"

try {
    Invoke-WithRetry -ScriptBlock {
        Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/ChromeStandaloneSetup64.exe" `
            -OutFile $chromeInstaller -UseBasicParsing -TimeoutSec 120
    }
    if ((Get-Item $chromeInstaller -ErrorAction SilentlyContinue).Length -gt 1MB) {
        Start-Process -FilePath $chromeInstaller -ArgumentList "/silent /install" -Wait
        Write-Host "Chrome installed. Installer left at: $chromeInstaller" -ForegroundColor Green
    } else {
        Write-Warning "Chrome installer download appears incomplete (size < 1MB)"
    }
} catch {
    Write-Warning "Chrome installation failed: $_"
}


# ----------------------------
# 9) Install Google Drive (direct download, installer kept on Desktop)
# ----------------------------
Write-Host "Apps: downloading and installing Google Drive..." -ForegroundColor Yellow

$gdriveInstaller = "$desktopPath\GoogleDriveSetup.exe"

try {
    Invoke-WithRetry -ScriptBlock {
        Invoke-WebRequest -Uri "https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe" `
            -OutFile $gdriveInstaller -UseBasicParsing -TimeoutSec 120
    }
    if ((Get-Item $gdriveInstaller -ErrorAction SilentlyContinue).Length -gt 1MB) {
        Start-Process -FilePath $gdriveInstaller -ArgumentList "--silent --desktop_shortcut" -Wait
        Write-Host "Google Drive installed. Installer left at: $gdriveInstaller" -ForegroundColor Green
    } else {
        Write-Warning "Google Drive installer download appears incomplete (size < 1MB)"
    }
} catch {
    Write-Warning "Google Drive installation failed: $_"
}


# ----------------------------
# 10) Install uv and Python
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

# Installs latest Python via uv. Pin a version if needed, e.g.: uv python install 3.12
uv python install


Write-Host "`n=== Done. A restart may be required for some changes. ===`n" -ForegroundColor Green
