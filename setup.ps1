<#
.SYNOPSIS
    Fast Windows workstation setup with hardening, applications, Chrome policies,
    Google Drive startup, dark mode and verification.

.DESCRIPTION
    Run from a normal PowerShell window. The script automatically elevates.
    Chrome and Google Drive require one interactive Google authentication on first use.
    No Google password is stored in this script, the registry or a scheduled task.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-optimised.ps1 -GmailAddress "name@gmail.com"

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-optimised.ps1 -GmailAddress "name@gmail.com" -ForceChromeSignIn
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[^\s@]+@[^\s@]+\.[^\s@]+$')]
    [string]$GmailAddress,

    [switch]$ForceChromeSignIn,
    [switch]$SkipHardening,
    [switch]$SkipVerification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# -----------------------------------------------------------------------------
# 1. Elevation
# -----------------------------------------------------------------------------

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', ('"{0}"' -f $PSCommandPath)
    )

    if ($GmailAddress) {
        $arguments += @('-GmailAddress', ('"{0}"' -f $GmailAddress))
    }
    if ($ForceChromeSignIn) { $arguments += '-ForceChromeSignIn' }
    if ($SkipHardening) { $arguments += '-SkipHardening' }
    if ($SkipVerification) { $arguments += '-SkipVerification' }

    Start-Process powershell.exe -Verb RunAs -ArgumentList ($arguments -join ' ')
    exit
}

Write-Host "`n=== Starting optimised workstation setup ===`n" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 2. Shared helpers and result tracking
# -----------------------------------------------------------------------------

$script:Results = [System.Collections.Generic.List[psobject]]::new()
$script:ToolPaths = @(
    "$env:ProgramFiles\nodejs"
    "$env:APPDATA\npm"
    "$env:LOCALAPPDATA\pnpm"
    "$env:USERPROFILE\.local\bin"
    "$env:LOCALAPPDATA\Programs\oh-my-posh\bin"
    "$env:ProgramData\chocolatey\bin"
    "$env:LOCALAPPDATA\Microsoft\WindowsApps"
)

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail = ''
    )

    $script:Results.Add([pscustomobject]@{
        Category = $Category
        Item     = $Item
        Status   = $Status
        Detail   = $Detail
    }) | Out-Null
}

function Update-SessionEnvironment {
    param([string[]]$EnsurePath = @())

    foreach ($scope in 'Machine', 'User') {
        $variables = [Environment]::GetEnvironmentVariables($scope)
        foreach ($name in $variables.Keys) {
            if ($name -ne 'Path') {
                [Environment]::SetEnvironmentVariable(
                    [string]$name,
                    [string]$variables[$name],
                    'Process'
                )
            }
        }
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'
        [Environment]::GetEnvironmentVariable('Path', 'User') -split ';'
        $env:Path -split ';'
        $EnsurePath
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $normalised = $candidate.Trim().TrimEnd('\')
        if (-not ($paths | Where-Object { $_ -ieq $normalised })) {
            $paths.Add($normalised)
        }
    }
    $env:Path = $paths -join ';'
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$EnsurePath = @()
    )

    if (Get-Command $Name -ErrorAction SilentlyContinue) { return $true }
    Update-SessionEnvironment -EnsurePath $EnsurePath
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-DownloadsFolder {
    try {
        $shellFolders = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $valueName = '{374DE290-123F-4565-9164-39C4925E467B}'
        $rawPath = (Get-ItemProperty -Path $shellFolders -Name $valueName -ErrorAction Stop).$valueName
        $expandedPath = [Environment]::ExpandEnvironmentVariables($rawPath)
        if ($expandedPath) {
            New-Item -Path $expandedPath -ItemType Directory -Force | Out-Null
            return $expandedPath
        }
    }
    catch {
        # Fall back below.
    }

    $fallback = Join-Path $env:USERPROFILE 'Downloads'
    New-Item -Path $fallback -ItemType Directory -Force | Out-Null
    return $fallback
}

function Install-FromWeb {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessExitCodes = @(0, 1641, 3010),
        [switch]$Msi
    )

    $installerPath = Join-Path $env:TEMP $FileName
    try {
        Write-Host "  Downloading $Name..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $Url -OutFile $installerPath -UseBasicParsing -ErrorAction Stop

        if ($Msi) {
            $process = Start-Process msiexec.exe -ArgumentList (@('/i', ('"{0}"' -f $installerPath), '/qn', '/norestart') + $ArgumentList) -Wait -PassThru
        }
        else {
            $process = Start-Process $installerPath -ArgumentList $ArgumentList -Wait -PassThru
        }

        if ($process.ExitCode -notin $SuccessExitCodes) {
            throw "$Name installer returned exit code $($process.ExitCode)."
        }
        return $true
    }
    catch {
        Write-Warning "$Name installation failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-RegValue {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Expected
    )

    try {
        $actual = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        if ([string]$actual -eq [string]$Expected) {
            Add-Result $Category $Item 'OK'
        }
        else {
            Add-Result $Category $Item 'WARN' "Expected $Expected, found $actual"
        }
    }
    catch {
        Add-Result $Category $Item 'FAIL' 'Value not set'
    }
}

# -----------------------------------------------------------------------------
# 3. Basic hardening
# -----------------------------------------------------------------------------

if (-not $SkipHardening) {
    Write-Host 'Hardening: applying protocol, authentication and service settings...' -ForegroundColor Yellow

    $protocolRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    foreach ($protocol in @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1')) {
        foreach ($role in @('Client', 'Server')) {
            $path = Join-Path $protocolRoot "$protocol\$role"
            New-Item -Path $path -Force | Out-Null
            New-ItemProperty -Path $path -Name Enabled -PropertyType DWord -Value 0 -Force | Out-Null
            New-ItemProperty -Path $path -Name DisabledByDefault -PropertyType DWord -Value 1 -Force | Out-Null
        }
    }

    foreach ($protocol in @('TLS 1.2', 'TLS 1.3')) {
        foreach ($role in @('Client', 'Server')) {
            $path = Join-Path $protocolRoot "$protocol\$role"
            New-Item -Path $path -Force | Out-Null
            New-ItemProperty -Path $path -Name Enabled -PropertyType DWord -Value 1 -Force | Out-Null
            New-ItemProperty -Path $path -Name DisabledByDefault -PropertyType DWord -Value 0 -Force | Out-Null
        }
    }

    try {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -Confirm:$false | Out-Null
        Add-Result 'Hardening' 'SMBv1 configuration' 'OK'
    }
    catch {
        Add-Result 'Hardening' 'SMBv1 configuration' 'WARN' $_.Exception.Message
    }

    $netBtPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
    if (Test-Path $netBtPath) {
        Get-ChildItem $netBtPath | ForEach-Object {
            New-ItemProperty -Path $_.PSPath -Name NetbiosOptions -PropertyType DWord -Value 2 -Force | Out-Null
        }
    }

    $lsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    New-ItemProperty -Path $lsaPath -Name LmCompatibilityLevel -PropertyType DWord -Value 5 -Force | Out-Null

    try {
        Disable-LocalUser -Name 'Guest' -ErrorAction Stop
    }
    catch {
        & net.exe user Guest /active:no 2>$null | Out-Null
    }

    $wdigestPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
    New-Item -Path $wdigestPath -Force | Out-Null
    New-ItemProperty -Path $wdigestPath -Name UseLogonCredential -PropertyType DWord -Value 0 -Force | Out-Null

    try {
        Stop-Service -Name AudioSrv -Force -ErrorAction SilentlyContinue
        Set-Service -Name AudioSrv -StartupType Disabled -ErrorAction Stop
        Add-Result 'Hardening' 'Windows Audio disabled' 'OK'
    }
    catch {
        Add-Result 'Hardening' 'Windows Audio disabled' 'WARN' $_.Exception.Message
    }
}
else {
    Add-Result 'Hardening' 'Hardening section' 'SKIP' 'Requested by parameter'
}

# -----------------------------------------------------------------------------
# 4. Windows Update policy and dark mode
# -----------------------------------------------------------------------------

Write-Host 'Windows: configuring update policy and dark mode...' -ForegroundColor Yellow

$wuRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$wuPolicy = Join-Path $wuRoot 'AU'
New-Item -Path $wuPolicy -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name NoAutoUpdate -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name AUOptions -PropertyType DWord -Value 3 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name NoAutoRebootWithLoggedOnUsers -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name RebootWarningTimeoutEnabled -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name ScheduledInstallDay -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $wuPolicy -Name ScheduledInstallTime -PropertyType DWord -Value 3 -Force | Out-Null
New-Item -Path $wuRoot -Force | Out-Null
New-ItemProperty -Path $wuRoot -Name SetActiveHours -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $wuRoot -Name ActiveHoursStart -PropertyType DWord -Value 6 -Force | Out-Null
New-ItemProperty -Path $wuRoot -Name ActiveHoursEnd -PropertyType DWord -Value 23 -Force | Out-Null

$personalise = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
New-Item -Path $personalise -Force | Out-Null
New-ItemProperty -Path $personalise -Name AppsUseLightTheme -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $personalise -Name SystemUsesLightTheme -PropertyType DWord -Value 0 -Force | Out-Null

$defaultPersonalise = 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
New-Item -Path $defaultPersonalise -Force | Out-Null
New-ItemProperty -Path $defaultPersonalise -Name AppsUseLightTheme -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $defaultPersonalise -Name SystemUsesLightTheme -PropertyType DWord -Value 0 -Force | Out-Null

# Restart Explorer so the dark mode setting is applied immediately.
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Process explorer.exe

# -----------------------------------------------------------------------------
# 5. Edge policies
# -----------------------------------------------------------------------------

Write-Host 'Edge: applying first-run and search policies...' -ForegroundColor Yellow

$edgePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
New-Item -Path $edgePolicy -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name HideFirstRunExperience -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name BrowserSignin -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name NewTabPageContentEnabled -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name PromotionalTabsEnabled -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name DefaultSearchProviderEnabled -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name DefaultSearchProviderName -PropertyType String -Value 'Google' -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name DefaultSearchProviderKeyword -PropertyType String -Value 'google.com' -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name DefaultSearchProviderSearchURL -PropertyType String -Value 'https://www.google.com/search?q={searchTerms}' -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name DefaultSearchProviderSuggestURL -PropertyType String -Value 'https://www.google.com/complete/search?output=chrome&q={searchTerms}' -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name DefaultSearchProviderIconURL -PropertyType String -Value 'https://www.google.com/favicon.ico' -Force | Out-Null

# -----------------------------------------------------------------------------
# 6. Chocolatey and applications - one package transaction
# -----------------------------------------------------------------------------

Write-Host 'Chocolatey: checking installation...' -ForegroundColor Yellow

if (-not (Test-CommandAvailable -Name choco -EnsurePath $script:ToolPaths)) {
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        Update-SessionEnvironment -EnsurePath $script:ToolPaths
    }
    catch {
        Add-Result 'Chocolatey' 'Installation' 'FAIL' $_.Exception.Message
    }
}

$packages = @(
    'winfsp'
    'rclone'
    'qbittorrent'
    '7zip'
    'git'
    'wiztree'
    'tailscale'
    'vscode'
    'nodejs'
    'vcredist140'
    'ffmpeg'
    'powershell-core'
)

if (Test-CommandAvailable -Name choco -EnsurePath $script:ToolPaths) {
    choco feature enable -n allowGlobalConfirmation --limit-output | Out-Null

    $missingPackages = [System.Collections.Generic.List[string]]::new()
    foreach ($package in $packages) {
        choco list --local-only --exact $package --limit-output 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $missingPackages.Add($package)
        }
        else {
            Add-Result 'Chocolatey' $package 'OK' 'Already installed'
        }
    }

    if ($missingPackages.Count -gt 0) {
        Write-Host "Apps: installing $($missingPackages.Count) Chocolatey packages in one transaction..." -ForegroundColor Yellow
        & choco install @($missingPackages) -y --no-progress --limit-output
        $installExit = $LASTEXITCODE
        Update-SessionEnvironment -EnsurePath $script:ToolPaths

        foreach ($package in $missingPackages) {
            choco list --local-only --exact $package --limit-output 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Add-Result 'Chocolatey' $package 'OK' 'Installed'
            }
            else {
                Add-Result 'Chocolatey' $package 'FAIL' "Transaction exit code $installExit"
            }
        }
    }
}
else {
    foreach ($package in $packages) {
        Add-Result 'Chocolatey' $package 'SKIP' 'Chocolatey unavailable'
    }
}

# -----------------------------------------------------------------------------
# 7. qBittorrent configuration
# -----------------------------------------------------------------------------

Write-Host 'qBittorrent: writing configuration...' -ForegroundColor Yellow

$qbConfigDir = Join-Path $env:APPDATA 'qBittorrent'
$qbConfigFile = Join-Path $qbConfigDir 'qBittorrent.ini'
New-Item -Path $qbConfigDir -ItemType Directory -Force | Out-Null

if (Test-Path $qbConfigFile) {
    Copy-Item $qbConfigFile "$qbConfigFile.bak" -Force
}

$userPathEscaped = $env:USERPROFILE -replace '\\', '\\'
$qbConfig = @"
[AddNewTorrentDialog]
SavePathHistory=$userPathEscaped\Downloads\z
DownloadPathHistory=$userPathEscaped\Downloads\temp
RememberLastSavePath=true

[LegalNotice]
Accepted=true

[Application]
FileLogger\AgeType=1
GUI\Notifications\TorrentAdded=false
FileLogger\DeleteOld=true
FileLogger\Age=1
FileLogger\Path=$userPathEscaped\AppData\Local\qBittorrent\logs
FileLogger\MaxSizeBytes=66560
FileLogger\Backup=true
FileLogger\Enabled=true

[BitTorrent]
Session\QueueingSystemEnabled=false
Session\ShareLimitAction=Remove
Session\TempPathEnabled=true
Session\GlobalUPSpeedLimit=0
Session\GlobalMaxRatio=0
Session\DefaultSavePath=$userPathEscaped\Downloads\z
Session\Port=35196
Session\SSL\Port=60785
Session\StartPaused=false

[GUI]
Log\Enabled=false
DownloadTrackerFavicon=false

[Meta]
MigrationVersion=8

[Preferences]
General\CloseToTrayNotified=true
General\Locale=en

[Core]
AutoDeleteAddedTorrentFile=IfAdded
"@

try {
    Set-Content -Path $qbConfigFile -Value $qbConfig -Encoding UTF8 -ErrorAction Stop
    Add-Result 'Configuration' 'qBittorrent' 'OK' $qbConfigFile
}
catch {
    Add-Result 'Configuration' 'qBittorrent' 'FAIL' $_.Exception.Message
}

# -----------------------------------------------------------------------------
# 8. uv, Python, pnpm, OpenCode and Oh My Posh
# -----------------------------------------------------------------------------

Write-Host 'Developer tools: installing only missing components...' -ForegroundColor Yellow

if (-not (Test-CommandAvailable -Name uv -EnsurePath $script:ToolPaths)) {
    try {
        Invoke-RestMethod 'https://astral.sh/uv/install.ps1' | Invoke-Expression
        Update-SessionEnvironment -EnsurePath $script:ToolPaths
    }
    catch {
        Add-Result 'Tools' 'uv' 'FAIL' $_.Exception.Message
    }
}

if (Test-CommandAvailable -Name uv -EnsurePath $script:ToolPaths) {
    try {
        & uv python find 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & uv python install
        }
        if ($LASTEXITCODE -eq 0) {
            Add-Result 'Tools' 'uv Python runtime' 'OK'
        }
        else {
            Add-Result 'Tools' 'uv Python runtime' 'WARN' "Exit code $LASTEXITCODE"
        }
    }
    catch {
        Add-Result 'Tools' 'uv Python runtime' 'WARN' $_.Exception.Message
    }
}

if (-not (Test-CommandAvailable -Name pnpm -EnsurePath $script:ToolPaths)) {
    if (Test-CommandAvailable -Name corepack -EnsurePath $script:ToolPaths) {
        & corepack enable
        & corepack prepare pnpm@latest --activate
        Update-SessionEnvironment -EnsurePath $script:ToolPaths
    }
    elseif (Test-CommandAvailable -Name npm -EnsurePath $script:ToolPaths) {
        & npm install --global pnpm --no-audit --no-fund
        Update-SessionEnvironment -EnsurePath $script:ToolPaths
    }
}
Add-Result 'Tools' 'pnpm' $(if (Test-CommandAvailable pnpm $script:ToolPaths) { 'OK' } else { 'WARN' })

if (-not (Test-CommandAvailable -Name opencode -EnsurePath $script:ToolPaths)) {
    if (Test-CommandAvailable -Name npm -EnsurePath $script:ToolPaths) {
        & npm install --global opencode-ai --no-audit --no-fund
        Update-SessionEnvironment -EnsurePath $script:ToolPaths
    }
}
Add-Result 'Tools' 'opencode' $(if (Test-CommandAvailable opencode $script:ToolPaths) { 'OK' } else { 'WARN' })

if (-not (Test-CommandAvailable -Name oh-my-posh -EnsurePath $script:ToolPaths)) {
    try {
        Invoke-RestMethod 'https://ohmyposh.dev/install.ps1' | Invoke-Expression
        Update-SessionEnvironment -EnsurePath $script:ToolPaths
    }
    catch {
        Add-Result 'Tools' 'Oh My Posh' 'FAIL' $_.Exception.Message
    }
}
Add-Result 'Tools' 'Oh My Posh' $(if (Test-CommandAvailable oh-my-posh $script:ToolPaths) { 'OK' } else { 'WARN' })

# -----------------------------------------------------------------------------
# 9. Google Drive for desktop
# -----------------------------------------------------------------------------

Write-Host 'Google Drive: checking installation...' -ForegroundColor Yellow

function Get-GoogleDriveExecutable {
    $searchPaths = @(
        "$env:ProgramFiles\Google\Drive File Stream\*\GoogleDriveFS.exe"
        "${env:ProgramFiles(x86)}\Google\Drive File Stream\*\GoogleDriveFS.exe"
    )

    return Get-ChildItem -Path $searchPaths -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

$driveExe = Get-GoogleDriveExecutable
if (-not $driveExe) {
    $driveInstalled = Install-FromWeb `
        -Name 'Google Drive for desktop' `
        -Url 'https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe' `
        -FileName 'GoogleDriveSetup.exe' `
        -ArgumentList @('--silent', '--desktop_shortcut=false', '--gsuite_shortcuts=false')

    if ($driveInstalled) {
        Start-Sleep -Seconds 2
        $driveExe = Get-GoogleDriveExecutable
    }
}

if ($driveExe) {
    Add-Result 'Applications' 'Google Drive' 'OK' $driveExe.FullName

    try {
        $taskName = 'Start Google Drive'
        $taskAction = New-ScheduledTaskAction -Execute $driveExe.FullName
        $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $taskAction `
            -Trigger $taskTrigger `
            -Principal $taskPrincipal `
            -Description 'Starts Google Drive for desktop when the user signs in.' `
            -Force | Out-Null

        Add-Result 'Startup' 'Google Drive at logon' 'OK' $identity.Name
    }
    catch {
        Add-Result 'Startup' 'Google Drive at logon' 'WARN' $_.Exception.Message
    }

    $driveRunning = Get-Process GoogleDriveFS -ErrorAction SilentlyContinue
    if (-not $driveRunning) {
        Start-Process $driveExe.FullName
    }
}
else {
    Add-Result 'Applications' 'Google Drive' 'FAIL' 'Executable not found after installation'
}

# -----------------------------------------------------------------------------
# 10. Chrome installation and sign-in policies
# -----------------------------------------------------------------------------

Write-Host 'Chrome: checking installation and applying sign-in policies...' -ForegroundColor Yellow

$chromeExe = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $chromeExe)) {
    $chromeInstalled = Install-FromWeb `
        -Name 'Google Chrome Enterprise' `
        -Url 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' `
        -FileName 'googlechromestandaloneenterprise64.msi' `
        -Msi

    if (-not $chromeInstalled) {
        Add-Result 'Applications' 'Google Chrome' 'FAIL' 'MSI installation failed'
    }
}

if (Test-Path $chromeExe) {
    Add-Result 'Applications' 'Google Chrome' 'OK' $chromeExe

    $chromePolicy = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    New-Item -Path $chromePolicy -Force | Out-Null

    $browserSigninValue = if ($ForceChromeSignIn) { 2 } else { 1 }
    New-ItemProperty -Path $chromePolicy -Name BrowserSignin -PropertyType DWord -Value $browserSigninValue -Force | Out-Null

    if ($GmailAddress) {
        New-ItemProperty -Path $chromePolicy -Name RestrictSigninToPattern -PropertyType String -Value $GmailAddress -Force | Out-Null
        Add-Result 'Chrome' 'Permitted primary account' 'OK' $GmailAddress
    }
    else {
        Add-Result 'Chrome' 'Permitted primary account' 'SKIP' 'No GmailAddress parameter supplied'
    }

    New-ItemProperty -Path $chromePolicy -Name HideFirstRunExperience -PropertyType DWord -Value 1 -Force | Out-Null
    Add-Result 'Chrome' 'Browser sign-in policy' 'OK' "BrowserSignin=$browserSigninValue"

    $signInUrl = if ($GmailAddress) {
        'https://accounts.google.com/AccountChooser?Email=' + [uri]::EscapeDataString($GmailAddress) + '&continue=https%3A%2F%2Fmail.google.com%2F'
    }
    else {
        'https://accounts.google.com/'
    }

    Start-Process $chromeExe -ArgumentList @('--new-window', $signInUrl)
}
else {
    Add-Result 'Applications' 'Google Chrome' 'FAIL' 'chrome.exe not found'
}

# -----------------------------------------------------------------------------
# 11. Verification
# -----------------------------------------------------------------------------

if (-not $SkipVerification) {
    Write-Host 'Verification: checking applied settings and installed commands...' -ForegroundColor Yellow

    if (-not $SkipHardening) {
        foreach ($protocol in @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1')) {
            Test-RegValue 'Verify' "$protocol disabled" "$protocolRoot\$protocol\Server" Enabled 0
        }
        foreach ($protocol in @('TLS 1.2', 'TLS 1.3')) {
            Test-RegValue 'Verify' "$protocol enabled" "$protocolRoot\$protocol\Server" Enabled 1
        }
        Test-RegValue 'Verify' 'NTLMv1 disabled' $lsaPath LmCompatibilityLevel 5
        Test-RegValue 'Verify' 'WDigest caching disabled' $wdigestPath UseLogonCredential 0
    }

    Test-RegValue 'Verify' 'Update download and notify' $wuPolicy AUOptions 3
    Test-RegValue 'Verify' 'No reboot while logged on' $wuPolicy NoAutoRebootWithLoggedOnUsers 1
    Test-RegValue 'Verify' 'Dark mode for applications' $personalise AppsUseLightTheme 0
    Test-RegValue 'Verify' 'Edge first run hidden' $edgePolicy HideFirstRunExperience 1

    $chromePolicy = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    Test-RegValue 'Verify' 'Chrome browser sign-in' $chromePolicy BrowserSignin $(if ($ForceChromeSignIn) { 2 } else { 1 })
    if ($GmailAddress) {
        Test-RegValue 'Verify' 'Chrome account restriction' $chromePolicy RestrictSigninToPattern $GmailAddress
    }

    foreach ($command in @('choco', 'git', 'node', 'npm', 'uv', 'pnpm', 'opencode', 'oh-my-posh', 'rclone', 'ffmpeg')) {
        $found = Get-Command $command -ErrorAction SilentlyContinue
        if ($found) {
            Add-Result 'PATH' $command 'OK' $found.Source
        }
        else {
            Add-Result 'PATH' $command 'WARN' 'Not resolvable in this session'
        }
    }
}
else {
    Add-Result 'Verification' 'Verification pass' 'SKIP' 'Requested by parameter'
}

# -----------------------------------------------------------------------------
# 12. Summary
# -----------------------------------------------------------------------------

Write-Host "`n"
Write-Host ('=' * 100) -ForegroundColor Cyan
Write-Host ' SETUP SUMMARY' -ForegroundColor Cyan
Write-Host ('=' * 100) -ForegroundColor Cyan

$script:Results |
    Sort-Object Category, Item |
    Format-Table Category, Item, Status, Detail -AutoSize -Wrap

$counts = @{}
foreach ($status in @('OK', 'WARN', 'FAIL', 'SKIP')) {
    $counts[$status] = @($script:Results | Where-Object Status -eq $status).Count
}

Write-Host ("OK: {0}   WARN: {1}   FAIL: {2}   SKIP: {3}" -f $counts.OK, $counts.WARN, $counts.FAIL, $counts.SKIP) -ForegroundColor Cyan

try {
    $logPath = Join-Path (Get-DownloadsFolder) ("setup-summary-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $script:Results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
    Write-Host "Full summary saved to: $logPath" -ForegroundColor DarkGray
}
catch {
    Write-Warning "Could not save summary CSV: $($_.Exception.Message)"
}

Write-Host "`nFirst-run action required:" -ForegroundColor Yellow
Write-Host '1. Complete the Google sign-in opened in Chrome.' -ForegroundColor White
Write-Host '2. Complete Google Drive authentication when its sign-in window appears.' -ForegroundColor White
Write-Host '3. Subsequent Windows sign-ins will start Drive and resume synchronisation automatically.' -ForegroundColor White
Write-Host "`n=== Setup complete. Restart Windows to fully apply protocol and service changes. ===`n" -ForegroundColor Green
