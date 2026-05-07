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

choco install $packages -y --no-progress


# ----------------------------
# 7) Install Google Chrome (direct download)
# ----------------------------
Write-Host "Apps: downloading and installing Google Chrome..." -ForegroundColor Yellow

$chromeTmp = "$env:TEMP\ChromeStandaloneSetup64.exe"

try {
    Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/ChromeStandaloneSetup64.exe" `
        -OutFile $chromeTmp -UseBasicParsing
    Start-Process -FilePath $chromeTmp -ArgumentList "/silent /install" -Wait
    Write-Host "Chrome installed successfully." -ForegroundColor Green
} catch {
    Write-Warning "Chrome installation failed: $_"
} finally {
    if (Test-Path $chromeTmp) { Remove-Item $chromeTmp -Force }
}


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
refreshenv 2>$null

$env:Path =
    [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
    [Environment]::GetEnvironmentVariable("Path","User")

# Installs latest Python via uv. Pin a version if needed, e.g.: uv python install 3.12
uv python install


Write-Host "`n=== Done. A restart may be required for some changes. ===`n" -ForegroundColor Green
