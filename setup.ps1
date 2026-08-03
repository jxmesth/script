<#
Windows hardening + Chocolatey apps + Dark Mode + Edge policies
Plus: opencode (npm), oh-my-posh, Google Drive, Google Chrome
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
# 1b) Reliable in-session environment refresh
#     Replacement for Chocolatey's `refreshenv`, which silently no-ops when
#     the choco profile module isn't loaded and which drops session-only
#     PATH entries added by installers earlier in this same run.
# ----------------------------

function Update-SessionEnvironment {
    <#
      Re-reads Machine + User environment variables straight from the registry
      and rebuilds the current process environment - no new terminal needed.
      Preserves session-only PATH entries and de-duplicates the result.
    #>
    [CmdletBinding()]
    param(
        # Extra directories to guarantee are on PATH (e.g. tool bin folders)
        [string[]] $EnsurePath = @()
    )

    $machineKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $userKey    = 'HKCU:\Environment'

    # Capture what's in the session right now so we don't lose runtime-only additions
    $sessionPath = if ($env:Path) { $env:Path -split ';' } else { @() }

    # Variables that must never be clobbered by a registry value
    $protected = @('PROCESSOR_ARCHITECTURE', 'USERNAME', 'USERDOMAIN', 'HOMEDRIVE', 'HOMEPATH', 'PSModulePath')

    foreach ($key in @($machineKey, $userKey)) {
        if (-not (Test-Path $key)) { continue }

        $regKey = if ($key -eq $machineKey) {
            [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
        } else {
            [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
        }
        if (-not $regKey) { continue }

        foreach ($name in $regKey.GetValueNames()) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -eq 'Path')                    { continue }  # handled separately below
            if ($protected -contains $name)          { continue }

            # DoNotExpandEnvironmentNames keeps REG_EXPAND_SZ raw (e.g. "%SystemRoot%\..."),
            # which we then expand ourselves - this is exactly where refreshenv often breaks.
            $raw = $regKey.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $raw) { continue }

            $expanded = [Environment]::ExpandEnvironmentVariables([string]$raw)
            Set-Item -Path "Env:$name" -Value $expanded -Force -ErrorAction SilentlyContinue
        }
        $regKey.Close()
    }

    # Rebuild PATH: Machine + User + anything added during this session + explicit extras
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')

    $combined = @()
    $combined += ($machinePath -split ';')
    $combined += ($userPath    -split ';')
    $combined += $sessionPath
    $combined += $EnsurePath

    # De-duplicate case-insensitively, strip empties and trailing slashes
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $final = New-Object 'System.Collections.Generic.List[string]'

    foreach ($p in $combined) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $clean = [Environment]::ExpandEnvironmentVariables($p.Trim().TrimEnd('\'))
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        if ($seen.Add($clean)) { $final.Add($clean) | Out-Null }
    }

    $env:Path = ($final -join ';')

    # Nudge PowerShell to re-scan PATH for native executables instead of reusing
    # a stale "command not found" result from earlier in this session.
    try {
        Get-Command -CommandType Application -ErrorAction SilentlyContinue | Out-Null
    } catch { }

    Write-Host "  Environment refreshed ($($final.Count) PATH entries)." -ForegroundColor DarkGray
}

function Test-CommandAvailable {
    <#
      Checks for a command, and if missing, refreshes the environment once
      and re-checks before giving up. Saves a lot of "X not available" warnings.
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $EnsurePath = @()
    )

    if (Get-Command $Name -ErrorAction SilentlyContinue) { return $true }

    Write-Host "  '$Name' not found - refreshing environment and retrying..." -ForegroundColor DarkGray
    Update-SessionEnvironment -EnsurePath $EnsurePath

    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Common tool bin locations that installers add but that don't always
# land in the registry PATH before we need them.
$script:ToolPaths = @(
    "$env:ProgramFiles\nodejs"
    "$env:APPDATA\npm"
    "$env:LOCALAPPDATA\pnpm"
    "$env:USERPROFILE\.local\bin"
    "$env:LOCALAPPDATA\Programs\oh-my-posh\bin"
    "$env:ProgramData\chocolatey\bin"
    "$env:LOCALAPPDATA\Microsoft\WindowsApps"
)


# ----------------------------
# 1c) Result tracking (feeds the summary table at the end)
# ----------------------------

$script:Results = New-Object 'System.Collections.Generic.List[psobject]'

function Add-Result {
    param(
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Item,
        [Parameter(Mandatory)] [ValidateSet('OK','WARN','FAIL','SKIP')] [string] $Status,
        [string] $Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
        Category = $Category
        Item     = $Item
        Status   = $Status
        Detail   = $Detail
    }) | Out-Null
}

function Test-RegValue {
    <# Verifies a registry value equals an expected value; records the result. #>
    param(
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Item,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Expected
    )
    try {
        $actual = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        if ("$actual" -eq "$Expected") {
            Add-Result -Category $Category -Item $Item -Status 'OK'
        } else {
            Add-Result -Category $Category -Item $Item -Status 'WARN' -Detail "expected $Expected, found $actual"
        }
    } catch {
        Add-Result -Category $Category -Item $Item -Status 'FAIL' -Detail 'value not set'
    }
}


# ----------------------------
# 2) Basic hardening
#    - Disable SSL 2.0/3.0 and TLS 1.0/1.1
#    - Ensure TLS 1.2 and TLS 1.3 enabled
#    - Disable SMBv1
#    - Disable NetBIOS
#    - Disable NTLMv1
#    - Disable Guest account
#    - Disable WDigest credential caching
#    - Disable Windows Audio service
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

Write-Host "Hardening: stopping and disabling Windows Audio service..." -ForegroundColor Yellow
Stop-Service -Name "AudioSrv" -Force -ErrorAction SilentlyContinue
Set-Service  -Name "AudioSrv" -StartupType Disabled


# ----------------------------
# 3) Windows Update policy
#    - Updates download automatically
#    - Reboots require manual approval (no forced/scheduled restarts)
#    - Notifications shown so you know when a restart is pending
# ----------------------------
Write-Host "Updates: configuring download-only, no auto-reboot policy..." -ForegroundColor Yellow

$wuPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path $wuPolicy)) { New-Item -Path $wuPolicy -Force | Out-Null }

# AUOptions=3 - auto-download, notify for install (never silently installs or reboots)
# Alternatives: 2=notify before download, 3=auto-download+notify, 4=auto-download+auto-install
New-ItemProperty -Path $wuPolicy -Name "NoAutoUpdate"          -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name "AUOptions"             -PropertyType DWord -Value 3 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name "NoAutoRebootWithLoggedOnUsers" -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name "RebootWarningTimeoutEnabled"   -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name "ScheduledInstallDay"   -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name "ScheduledInstallTime"  -PropertyType DWord -Value 3 -Force | Out-Null

# Block forced reboots via the WindowsUpdate key (separate from AU)
$wuRoot = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
if (-not (Test-Path $wuRoot)) { New-Item -Path $wuRoot -Force | Out-Null }
New-ItemProperty -Path $wuRoot -Name "SetActiveHours"         -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $wuRoot -Name "ActiveHoursStart"       -PropertyType DWord -Value 6 -Force | Out-Null  # 06:00
New-ItemProperty -Path $wuRoot -Name "ActiveHoursEnd"         -PropertyType DWord -Value 23 -Force | Out-Null # 23:00
# Active hours window = 17 hrs; Windows won't auto-reboot during this window.
# The remaining 1-hr gap (23:00-06:00) is intentionally narrow to minimize surprise reboots.
# If you want to fully block auto-reboots at ALL times, set ActiveHoursEnd=5 and ActiveHoursStart=6
# (max 18-hr window) and rely on NoAutoRebootWithLoggedOnUsers above for the rest.

Write-Host "  Updates will download automatically." -ForegroundColor DarkGray
Write-Host "  Reboots require your manual initiation." -ForegroundColor DarkGray


# ----------------------------
# 4) Windows Dark Mode
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
# 5) Microsoft Edge policies
#    - Disable first run, nags, content
#    - Set Google as default search engine
# ----------------------------
Write-Host "Edge: applying policies (no first-run, Google search)..." -ForegroundColor Yellow

$edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
New-Item -Path $edgePolicy -Force | Out-Null

New-ItemProperty -Path $edgePolicy -Name "HideFirstRunExperience"          -PropertyType DWord  -Value 1            -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "BrowserSignin"                   -PropertyType DWord  -Value 0            -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "NewTabPageContentEnabled"        -PropertyType DWord  -Value 0            -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "PromotionalTabsEnabled"          -PropertyType DWord  -Value 0            -Force | Out-Null

New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderEnabled"    -PropertyType DWord  -Value 1            -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderName"       -PropertyType String -Value "Google"     -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderKeyword"    -PropertyType String -Value "google.com" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderSearchURL"  -PropertyType String -Value "https://www.google.com/search?q={searchTerms}" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderSuggestURL" -PropertyType String -Value "https://www.google.com/complete/search?output=chrome&q={searchTerms}" -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name "DefaultSearchProviderIconURL"    -PropertyType String -Value "https://www.google.com/favicon.ico" -Force | Out-Null


# ----------------------------
# 6) Install Chocolatey (if missing)
# ----------------------------
Write-Host "Chocolatey: checking/installing..." -ForegroundColor Yellow

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
}

# Refresh PATH so choco is available in this session
Update-SessionEnvironment -EnsurePath $script:ToolPaths

# Suppress interactive confirmation prompts (does NOT affect hash verification)
if (Test-CommandAvailable -Name "choco" -EnsurePath $script:ToolPaths) {
    choco feature enable -n allowGlobalConfirmation | Out-Null
} else {
    Write-Warning "choco still not resolvable after environment refresh."
}


# ----------------------------
# 7) Install apps via Chocolatey
# ----------------------------
Write-Host "Apps: installing via Chocolatey..." -ForegroundColor Yellow

$packages = @(
    "winfsp",
    "rclone",
    "qbittorrent",
    "7zip",
    "git",
    "wiztree",
    "tailscale",
    "vscode",
    "nodejs",
    "python",
    "vcredist140",
    "ffmpeg",
    "powershell-core"
)

if (-not (Test-CommandAvailable -Name "choco" -EnsurePath $script:ToolPaths)) {
    Write-Warning "Chocolatey not available - skipping package install."
    foreach ($pkg in $packages) {
        Add-Result -Category 'Choco' -Item $pkg -Status 'SKIP' -Detail 'choco unavailable'
    }
} else {
    # Installed one-by-one so a single bad package can't mask the rest,
    # and so the summary table can report per-package status.
    foreach ($pkg in $packages) {
        Write-Host "  -> $pkg" -ForegroundColor DarkGray
        choco install $pkg -y --no-progress --limit-output | Out-Null
        $code = $LASTEXITCODE

        switch ($code) {
            0       { Add-Result -Category 'Choco' -Item $pkg -Status 'OK' }
            1641    { Add-Result -Category 'Choco' -Item $pkg -Status 'OK'   -Detail 'reboot initiated' }
            3010    { Add-Result -Category 'Choco' -Item $pkg -Status 'OK'   -Detail 'reboot required' }
            default { Add-Result -Category 'Choco' -Item $pkg -Status 'FAIL' -Detail "exit code $code"
                      Write-Warning "$pkg failed with exit code $code." }
        }
    }
}


# ----------------------------
# 8) Configure qBittorrent (write config before first launch)
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

try {
    Set-Content -Path $qbConfigFile -Value $qbConfig -Encoding UTF8 -ErrorAction Stop
    Write-Host "qBittorrent config written to: $qbConfigFile" -ForegroundColor Green
    Add-Result -Category 'Config' -Item 'qBittorrent.ini' -Status 'OK'
} catch {
    Write-Warning "qBittorrent config write failed: $_"
    Add-Result -Category 'Config' -Item 'qBittorrent.ini' -Status 'FAIL' -Detail $_.Exception.Message
}


# ----------------------------
# 9) Install uv and Python
# ----------------------------
Write-Host "Apps: installing uv (Python manager)..." -ForegroundColor Yellow

try {
    Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
} catch {
    Write-Warning "uv installation failed: $_"
    Add-Result -Category 'Tools' -Item 'uv (install script)' -Status 'FAIL' -Detail $_.Exception.Message
}

Write-Host "Refreshing PATH..."
Update-SessionEnvironment -EnsurePath $script:ToolPaths

# Pin a version for reproducibility if needed, e.g.: uv python install 3.12
if (Test-CommandAvailable -Name "uv" -EnsurePath $script:ToolPaths) {
    uv python install
    if ($LASTEXITCODE -eq 0) {
        Add-Result -Category 'Tools' -Item 'uv python runtime' -Status 'OK'
    } else {
        Add-Result -Category 'Tools' -Item 'uv python runtime' -Status 'WARN' -Detail "exit code $LASTEXITCODE"
    }
} else {
    Write-Warning "uv not resolvable after environment refresh - skipping 'uv python install'."
    Add-Result -Category 'Tools' -Item 'uv python runtime' -Status 'SKIP' -Detail 'uv not on PATH'
}


# ----------------------------
# 10) Install pnpm
# ----------------------------
Write-Host "Apps: installing pnpm..." -ForegroundColor Yellow

try {
    Invoke-WebRequest https://get.pnpm.io/install.ps1 -UseBasicParsing | Invoke-Expression
} catch {
    Write-Warning "pnpm installation failed: $_"
    Add-Result -Category 'Tools' -Item 'pnpm' -Status 'FAIL' -Detail $_.Exception.Message
}

Update-SessionEnvironment -EnsurePath $script:ToolPaths


# ----------------------------
# 11) Install opencode via npm
# ----------------------------
Write-Host "Apps: installing opencode-ai via npm..." -ForegroundColor Yellow

if (Test-CommandAvailable -Name "npm" -EnsurePath $script:ToolPaths) {
    try {
        npm i -g opencode-ai
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "npm i -g opencode-ai exited with code $LASTEXITCODE."
            Add-Result -Category 'Tools' -Item 'opencode-ai' -Status 'FAIL' -Detail "npm exit code $LASTEXITCODE"
        } else {
            Write-Host "  opencode-ai installed." -ForegroundColor Green
            Add-Result -Category 'Tools' -Item 'opencode-ai' -Status 'OK'
        }
    } catch {
        Write-Warning "opencode-ai installation failed: $_"
        Add-Result -Category 'Tools' -Item 'opencode-ai' -Status 'FAIL' -Detail $_.Exception.Message
    }
} else {
    Write-Warning "npm not available even after environment refresh (is Node.js installed?) - skipping opencode-ai install."
    Add-Result -Category 'Tools' -Item 'opencode-ai' -Status 'SKIP' -Detail 'npm not on PATH'
}


# ----------------------------
# 12) Install oh-my-posh (omp)
# ----------------------------
Write-Host "Apps: installing oh-my-posh..." -ForegroundColor Yellow

try {
    Invoke-RestMethod https://omp.sh/install.ps1 | Invoke-Expression
    Write-Host "  oh-my-posh install script completed." -ForegroundColor Green
} catch {
    Write-Warning "oh-my-posh installation failed: $_"
    Add-Result -Category 'Tools' -Item 'oh-my-posh (script)' -Status 'FAIL' -Detail $_.Exception.Message
}

# Refresh PATH so 'oh-my-posh' is usable in this session
if (-not (Test-CommandAvailable -Name "oh-my-posh" -EnsurePath $script:ToolPaths)) {
    Write-Warning "oh-my-posh not found on PATH even after environment refresh - verify in a new shell with: oh-my-posh --version"
}


# ----------------------------
# 13) Helper: resolve Downloads folder + download/run installers
# ----------------------------

function Get-DownloadsFolder {
    # Honors a relocated Downloads folder; falls back to the default path.
    try {
        $shellFolders = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
        $path = (Get-ItemProperty -Path $shellFolders -Name "{374DE290-123F-4565-9164-39C4925E467B}" -ErrorAction Stop)."{374DE290-123F-4565-9164-39C4925E467B}"
        if ($path -and (Test-Path $path)) { return $path }
    } catch { }

    $fallback = Join-Path $env:USERPROFILE "Downloads"
    if (-not (Test-Path $fallback)) {
        New-Item -Path $fallback -ItemType Directory -Force | Out-Null
    }
    return $fallback
}

function Install-FromWeb {
    <#
      Downloads an installer into Downloads and runs it silently.
      Warns (never throws) on download or install failure so the script keeps going.
    #>
    param(
        [Parameter(Mandatory)] [string]   $Name,
        [Parameter(Mandatory)] [string]   $Url,
        [Parameter(Mandatory)] [string]   $FileName,
        [string[]] $ArgumentList = @(),
        [int[]]    $SuccessExitCodes = @(0, 3010, 1641)
    )

    $dest = Join-Path (Get-DownloadsFolder) $FileName

    Write-Host "  Downloading $Name -> $dest" -ForegroundColor DarkGray
    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
    } catch {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Warning "$Name download FAILED from $Url : $_"
        return $false
    }

    if (-not (Test-Path $dest) -or ((Get-Item $dest).Length -lt 100KB)) {
        Write-Warning "$Name download looks invalid or truncated ($dest). Skipping install."
        return $false
    }

    Write-Host "  Running $Name installer..." -ForegroundColor DarkGray
    try {
        if ($ArgumentList.Count -gt 0) {
            $proc = Start-Process -FilePath $dest -ArgumentList $ArgumentList -Wait -PassThru -ErrorAction Stop
        } else {
            $proc = Start-Process -FilePath $dest -Wait -PassThru -ErrorAction Stop
        }
    } catch {
        Write-Warning "$Name installer could not be launched: $_"
        return $false
    }

    if ($SuccessExitCodes -contains $proc.ExitCode) {
        Write-Host "  $Name installed successfully (exit code $($proc.ExitCode))." -ForegroundColor Green
        return $true
    } else {
        Write-Warning "$Name installer exited with code $($proc.ExitCode) - installation may have failed. Installer kept at: $dest"
        return $false
    }
}


# ----------------------------
# 14) Install Google Drive for desktop
# ----------------------------
Write-Host "Apps: installing Google Drive for desktop..." -ForegroundColor Yellow

$driveInstalled = Install-FromWeb `
    -Name "Google Drive" `
    -Url  "https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe" `
    -FileName "GoogleDriveSetup.exe" `
    -ArgumentList @("--silent", "--desktop_shortcut=false", "--gsuite_shortcuts=false", "--skip_launch_new")

if ($driveInstalled) {
    Add-Result -Category 'Apps' -Item 'Google Drive' -Status 'OK'
} else {
    Write-Warning "Google Drive setup did not complete cleanly. You can run the downloaded GoogleDriveSetup.exe manually from your Downloads folder."
    Add-Result -Category 'Apps' -Item 'Google Drive' -Status 'FAIL' -Detail 'see Downloads for installer'
}


# ----------------------------
# 15) Install Google Chrome (Enterprise x64 MSI)
# ----------------------------
Write-Host "Apps: installing Google Chrome..." -ForegroundColor Yellow

# Canonical Chrome Enterprise x64 MSI - no installation-ID / tracking parameters.
$chromeUrl = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
$chromeMsi = Join-Path (Get-DownloadsFolder) "googlechromestandaloneenterprise64.msi"

$chromeOk = $false
try {
    $ProgressPreference = 'SilentlyContinue'
    Write-Host "  Downloading Chrome MSI -> $chromeMsi" -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $chromeUrl -OutFile $chromeMsi -UseBasicParsing -ErrorAction Stop

    if ((Get-Item $chromeMsi).Length -lt 1MB) {
        throw "Downloaded MSI is only $((Get-Item $chromeMsi).Length) bytes - likely not a valid installer."
    }

    Write-Host "  Running msiexec (silent)..." -ForegroundColor DarkGray
    $msi = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList @("/i", "`"$chromeMsi`"", "/qn", "/norestart") `
        -Wait -PassThru -ErrorAction Stop

    if ($msi.ExitCode -in 0, 3010, 1641) {
        Write-Host "  Google Chrome installed successfully (exit code $($msi.ExitCode))." -ForegroundColor Green
        $chromeOk = $true
    } else {
        Write-Warning "Chrome MSI failed with exit code $($msi.ExitCode). MSI kept at: $chromeMsi"
        Add-Result -Category 'Apps' -Item 'Google Chrome' -Status 'FAIL' -Detail "msiexec exit code $($msi.ExitCode)"
    }
} catch {
    Write-Warning "Google Chrome install FAILED: $_"
    Write-Warning "Try manually: msiexec /i `"$chromeMsi`" /qn /norestart"
    Add-Result -Category 'Apps' -Item 'Google Chrome' -Status 'FAIL' -Detail $_.Exception.Message
}

if ($chromeOk) {
    $chromeExe = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    if (Test-Path $chromeExe) {
        Add-Result -Category 'Apps' -Item 'Google Chrome' -Status 'OK'
    } else {
        Write-Warning "Chrome reported success but chrome.exe was not found at $chromeExe - please verify manually."
        Add-Result -Category 'Apps' -Item 'Google Chrome' -Status 'WARN' -Detail 'installer OK but exe not found'
    }
}


# ----------------------------
# 16) Verification pass
#     Re-reads the system to confirm what actually took effect, rather than
#     trusting that each earlier command succeeded.
# ----------------------------
Write-Host "`nVerifying applied settings..." -ForegroundColor Yellow

$schannel = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"

foreach ($proto in @("SSL 2.0", "SSL 3.0", "TLS 1.0", "TLS 1.1")) {
    Test-RegValue -Category 'Hardening' -Item "$proto disabled" `
        -Path "$schannel\$proto\Server" -Name 'Enabled' -Expected 0
}
foreach ($proto in @("TLS 1.2", "TLS 1.3")) {
    Test-RegValue -Category 'Hardening' -Item "$proto enabled" `
        -Path "$schannel\$proto\Server" -Name 'Enabled' -Expected 1
}

Test-RegValue -Category 'Hardening' -Item 'NTLMv1 disabled (LmCompat=5)' `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LmCompatibilityLevel' -Expected 5

Test-RegValue -Category 'Hardening' -Item 'WDigest cred caching off' `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name 'UseLogonCredential' -Expected 0

# SMBv1
try {
    $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
    if (-not $smb1) {
        Add-Result -Category 'Hardening' -Item 'SMBv1 disabled' -Status 'OK'
    } else {
        Add-Result -Category 'Hardening' -Item 'SMBv1 disabled' -Status 'FAIL' -Detail 'still enabled'
    }
} catch {
    Add-Result -Category 'Hardening' -Item 'SMBv1 disabled' -Status 'WARN' -Detail 'could not query'
}

# Guest account
try {
    $guest = Get-LocalUser -Name 'Guest' -ErrorAction Stop
    if (-not $guest.Enabled) {
        Add-Result -Category 'Hardening' -Item 'Guest account disabled' -Status 'OK'
    } else {
        Add-Result -Category 'Hardening' -Item 'Guest account disabled' -Status 'FAIL' -Detail 'still enabled'
    }
} catch {
    Add-Result -Category 'Hardening' -Item 'Guest account disabled' -Status 'WARN' -Detail 'could not query'
}

# Audio service
try {
    $audio = Get-Service -Name 'AudioSrv' -ErrorAction Stop
    if ($audio.StartType -eq 'Disabled') {
        Add-Result -Category 'Hardening' -Item 'Windows Audio disabled' -Status 'OK'
    } else {
        Add-Result -Category 'Hardening' -Item 'Windows Audio disabled' -Status 'WARN' -Detail "StartType=$($audio.StartType)"
    }
} catch {
    Add-Result -Category 'Hardening' -Item 'Windows Audio disabled' -Status 'WARN' -Detail 'service not found'
}

Test-RegValue -Category 'Updates' -Item 'Auto-download, notify install' `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'AUOptions' -Expected 3
Test-RegValue -Category 'Updates' -Item 'No auto-reboot when logged on' `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoRebootWithLoggedOnUsers' -Expected 1

Test-RegValue -Category 'UI' -Item 'Dark mode (apps)' `
    -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -Expected 0
Test-RegValue -Category 'UI' -Item 'Dark mode (system)' `
    -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -Expected 0

Test-RegValue -Category 'Edge' -Item 'First-run hidden' `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'HideFirstRunExperience' -Expected 1
Test-RegValue -Category 'Edge' -Item 'Default search = Google' `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'DefaultSearchProviderName' -Expected 'Google'

# Command-line tools actually resolvable
foreach ($cmd in @('choco','git','node','npm','python','uv','pnpm','opencode','oh-my-posh','rclone','ffmpeg')) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) {
        Add-Result -Category 'PATH' -Item $cmd -Status 'OK' -Detail $found.Source
    } else {
        Add-Result -Category 'PATH' -Item $cmd -Status 'WARN' -Detail 'not resolvable in this session'
    }
}

# Google Drive presence
$drivePath = "$env:ProgramFiles\Google\Drive File Stream"
if (Test-Path $drivePath) {
    Add-Result -Category 'Verify' -Item 'Google Drive installed' -Status 'OK'
} else {
    Add-Result -Category 'Verify' -Item 'Google Drive installed' -Status 'WARN' -Detail 'install dir not found'
}


# ----------------------------
# 17) Summary table
# ----------------------------

$colorFor = @{ 'OK' = 'Green'; 'WARN' = 'Yellow'; 'FAIL' = 'Red'; 'SKIP' = 'DarkGray' }

Write-Host "`n"
Write-Host ("=" * 92) -ForegroundColor Cyan
Write-Host " SETUP SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 92) -ForegroundColor Cyan

$hdr = "{0,-10} {1,-32} {2,-6} {3}" -f 'CATEGORY', 'ITEM', 'STATUS', 'DETAIL'
Write-Host $hdr -ForegroundColor White
Write-Host ("-" * 92) -ForegroundColor DarkGray

foreach ($group in ($script:Results | Group-Object Category)) {
    foreach ($r in $group.Group) {
        $detail = $r.Detail
        if ($detail.Length -gt 40) { $detail = $detail.Substring(0, 37) + '...' }

        $item = $r.Item
        if ($item.Length -gt 32) { $item = $item.Substring(0, 29) + '...' }

        $line = "{0,-10} {1,-32} {2,-6} {3}" -f $group.Name, $item, $r.Status, $detail
        Write-Host $line -ForegroundColor $colorFor[$r.Status]
    }
}

Write-Host ("-" * 92) -ForegroundColor DarkGray

$ok   = @($script:Results | Where-Object { $_.Status -eq 'OK' }).Count
$warn = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$fail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$skip = @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count

Write-Host ""
Write-Host ("  OK: {0}" -f $ok)   -ForegroundColor Green   -NoNewline
Write-Host ("   WARN: {0}" -f $warn) -ForegroundColor Yellow -NoNewline
Write-Host ("   FAIL: {0}" -f $fail) -ForegroundColor Red    -NoNewline
Write-Host ("   SKIP: {0}" -f $skip) -ForegroundColor DarkGray

if ($fail -gt 0) {
    Write-Host "`nItems needing attention:" -ForegroundColor Red
    foreach ($f in ($script:Results | Where-Object { $_.Status -eq 'FAIL' })) {
        Write-Host ("  - [{0}] {1}: {2}" -f $f.Category, $f.Item, $f.Detail) -ForegroundColor Red
    }
}

# Persist a CSV next to the downloaded installers for later review
try {
    $logPath = Join-Path (Get-DownloadsFolder) ("setup-summary-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $script:Results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    Write-Host "`nFull summary saved to: $logPath" -ForegroundColor DarkGray
} catch {
    Write-Warning "Could not write summary CSV: $_"
}

Write-Host ("=" * 92) -ForegroundColor Cyan
Write-Host "`n=== Done. A restart may be required for some changes. ===`n" -ForegroundColor Green
