<#
.SYNOPSIS
    Installs WinVDDB - copies the board scripts into place, makes sure the
    dependencies are present, and registers the three scheduled tasks that run
    and supervise the display board.

.DESCRIPTION
    Run this from an elevated PowerShell on the display machine, from the folder
    you cloned the repository into:

        Set-ExecutionPolicy -Scope Process Bypass -Force
        .\install\Install-WinVDDB.ps1 -KioskUser 'Kiosk'

    It is safe to re-run: every step is idempotent and the tasks are registered
    with -Force, so an upgrade is just "git pull" followed by another run.

    What it does NOT do, on purpose:
      * it does not enable autologon (that writes a password into the registry -
        use Sysinternals Autologon instead, see the README);
      * it does not edit Panels.ps1. If C:\Scripts\Panels.ps1 already exists it
        is left alone unless you pass -OverwriteConfig, so your panel manifest
        survives an upgrade.

.PARAMETER InstallPath
    Where the board scripts live. Must be C:\Scripts unless you also edit the
    hard-coded paths in Panels.ps1 and the two .ahk files.

.PARAMETER KioskUser
    The account that logs in on the display. The launch and watchdog tasks run
    as this user in its interactive session - they create windows, so they
    cannot run as SYSTEM.

.PARAMETER RebootTime
    Time of day for the unattended daily reboot, 24h HH:mm.

.PARAMETER WatchdogMinutes
    How often the watchdog health-check pass runs.

.PARAMETER AhkExe
    Path to the AutoHotkey **v1** interpreter. Must match $AhkExe in Panels.ps1.

.PARAMETER OverwriteConfig
    Overwrite an existing Panels.ps1 with the repository's example manifest.

.PARAMETER SkipModule
    Do not try to install the VirtualDesktop PowerShell module (use when the
    machine has no internet access and you have side-loaded it already).
#>
[CmdletBinding()]
param(
    [string]$InstallPath     = 'C:\Scripts',
    [string]$KioskUser       = $env:USERNAME,
    [string]$RebootTime      = '04:00',
    [int]   $WatchdogMinutes = 5,
    [string]$AhkExe          = 'C:\Program Files\AutoHotkey\AutoHotkeyU64.exe',
    [switch]$OverwriteConfig,
    [switch]$SkipModule
)

$ErrorActionPreference = 'Stop'

# --- Output conventions ------------------------------------------------------
# cyan = info, green = success, yellow = warning, red = failure, magenta = the
# effective configuration echoed back at you.
function Info { param($m) Write-Host $m -ForegroundColor Cyan }
function Ok   { param($m) Write-Host $m -ForegroundColor Green }
function Warn { param($m) Write-Host $m -ForegroundColor Yellow }
function Fail { param($m) Write-Host $m -ForegroundColor Red }
function Var  { param($m) Write-Host $m -ForegroundColor Magenta }

$repoRoot   = Split-Path -Parent $PSScriptRoot
$sourceDir  = Join-Path $repoRoot 'scripts'
$logDir     = Join-Path $InstallPath 'Logs'
$configFile = Join-Path $InstallPath 'Panels.ps1'

Write-Host ''
Info '=== WinVDDB installer ==='
Var  "InstallPath     = $InstallPath"
Var  "KioskUser       = $KioskUser"
Var  "RebootTime      = $RebootTime"
Var  "WatchdogMinutes = $WatchdogMinutes"
Var  "AhkExe          = $AhkExe"
Var  "Source          = $sourceDir"
Write-Host ''

# --- Preflight ---------------------------------------------------------------
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'This installer must run from an elevated PowerShell (Run as administrator).'
    exit 1
}

if (-not (Test-Path $sourceDir)) {
    Fail "Cannot find the scripts folder at $sourceDir - run this from inside the cloned repository."
    exit 1
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Fail "Windows PowerShell 5.1 or later is required (found $($PSVersionTable.PSVersion))."
    exit 1
}

# AutoHotkey v1 is a hard requirement and there is no reliable package id for it,
# so check rather than guess. winget's AutoHotkey package tracks v2, whose syntax
# these scripts are NOT written in.
if (-not (Test-Path $AhkExe)) {
    Fail "AutoHotkey v1 was not found at $AhkExe"
    Warn 'Install AutoHotkey 1.1 from https://www.autohotkey.com/download/1.1/ and re-run,'
    Warn 'or pass -AhkExe with the real path. Note that AutoHotkey v2 will NOT work:'
    Warn 'every script here is v1 syntax. v1 and v2 can be installed side by side.'
    exit 1
}
Ok "AutoHotkey v1 found at $AhkExe"

try {
    $null = Get-LocalUser -Name $KioskUser -ErrorAction Stop
    Ok "Kiosk account '$KioskUser' exists"
} catch {
    Warn "Could not confirm a local account named '$KioskUser' - continuing, but the"
    Warn 'scheduled tasks will fail to register if the name is wrong (domain accounts'
    Warn 'should be given as DOMAIN\user).'
}

# --- The VirtualDesktop PowerShell module ------------------------------------
# Installed for AllUsers so the kiosk account sees it even though this installer
# runs as an administrator, which is often a different account.
if (-not $SkipModule) {
    if (Get-Module -ListAvailable -Name VirtualDesktop) {
        Ok 'VirtualDesktop PowerShell module already available'
    } else {
        Info 'Installing the VirtualDesktop PowerShell module from the PSGallery...'
        try {
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
            }
            Install-Module -Name VirtualDesktop -Scope AllUsers -Force -AllowClobber
            Ok 'VirtualDesktop module installed'
        } catch {
            Fail "Could not install the VirtualDesktop module: $($_.Exception.Message)"
            Warn 'Install it by hand with:  Install-Module VirtualDesktop -Scope AllUsers'
            exit 1
        }
    }
}

# --- Copy the scripts --------------------------------------------------------
Info "Copying board scripts to $InstallPath"
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
New-Item -ItemType Directory -Path $logDir      -Force | Out-Null

$keepConfig = (Test-Path $configFile) -and (-not $OverwriteConfig)
if ($keepConfig) {
    Warn 'Panels.ps1 already exists - keeping your panel manifest (-OverwriteConfig replaces it).'
}

Get-ChildItem $sourceDir -File | ForEach-Object {
    if ($_.Name -eq 'Panels.ps1' -and $keepConfig) { return }
    Copy-Item $_.FullName -Destination $InstallPath -Force
    Info "  $($_.Name)"
}
Ok 'Scripts in place'

if (-not $keepConfig) {
    Warn "Edit $configFile before the board is useful - the shipped panels point at example.lan."
}

# --- Scheduled tasks ---------------------------------------------------------
# Three tasks, and the split matters:
#   Start VDDB        launches the board once, in the user's interactive session
#   VDDB Watchdog     one health-check pass every few minutes, also interactive
#                     (it creates windows, so it cannot run as SYSTEM)
#   VDDB Daily Reboot runs as SYSTEM, since it only reads a file and reboots
Info 'Registering scheduled tasks'

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function New-BoardAction {
    param([string]$ScriptName)
    New-ScheduledTaskAction -Execute $psExe -WorkingDirectory $InstallPath `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $InstallPath $ScriptName))
}

$interactive = New-ScheduledTaskPrincipal -UserId $KioskUser -LogonType Interactive -RunLevel Highest

# 1. Start VDDB ---------------------------------------------------------------
$startSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName 'Start VDDB' -Force `
    -Description 'Launches the WinVDDB display board at logon.' `
    -Action    (New-BoardAction 'Launcher.ps1') `
    -Trigger   (New-ScheduledTaskTrigger -AtLogOn -User $KioskUser) `
    -Principal $interactive `
    -Settings  $startSettings | Out-Null
Ok '  Start VDDB          - at logon'

# 2. VDDB Watchdog ------------------------------------------------------------
# Two triggers: a repeating one that carries the board through the day, and a
# delayed logon trigger so the first pass lands after startup has finished.
# The repetition duration is 10 years rather than "indefinitely" because
# New-ScheduledTaskTrigger rejects an unbounded duration on some builds.
$watchdogRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes $WatchdogMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$watchdogLogon = New-ScheduledTaskTrigger -AtLogOn -User $KioskUser
$watchdogLogon.Delay = 'PT3M'

$watchdogSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
Register-ScheduledTask -TaskName 'VDDB Watchdog' -Force `
    -Description 'One WinVDDB health-check pass: restarts a dead rotation, relaunches missing panels.' `
    -Action    (New-BoardAction 'Watchdog-DisplayBoard.ps1') `
    -Trigger   @($watchdogRepeat, $watchdogLogon) `
    -Principal $interactive `
    -Settings  $watchdogSettings | Out-Null
Ok "  VDDB Watchdog       - every $WatchdogMinutes min, and 3 min after logon"

# 3. VDDB Daily Reboot --------------------------------------------------------
$systemPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$rebootSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
Register-ScheduledTask -TaskName 'VDDB Daily Reboot' -Force `
    -Description 'Unattended nightly reboot. Stands down while a panel is held with F3.' `
    -Action    (New-BoardAction 'DailySystemReboot.ps1') `
    -Trigger   (New-ScheduledTaskTrigger -Daily -At $RebootTime) `
    -Principal $systemPrincipal `
    -Settings  $rebootSettings | Out-Null
Ok "  VDDB Daily Reboot   - daily at $RebootTime"

# --- Done --------------------------------------------------------------------
Write-Host ''
Ok '=== WinVDDB installed ==='
Write-Host ''
Info 'Next steps:'
Write-Host "  1. Edit $configFile - one entry per desktop, and keep" -ForegroundColor White
Write-Host '     $TotalDesktops / $LastDesktop in step with it.' -ForegroundColor White
Write-Host '  2. Set up autologon for the kiosk account with Sysinternals Autologon' -ForegroundColor White
Write-Host '     (https://learn.microsoft.com/sysinternals/downloads/autologon).' -ForegroundColor White
Write-Host '  3. Reboot, or start the board now with:' -ForegroundColor White
Write-Host "       Start-ScheduledTask -TaskName 'Start VDDB'" -ForegroundColor White
Write-Host ''
Warn 'The board must run in an interactive session. A process started over SSH lands'
Warn 'in Session 0 and can neither see nor create windows on the display.'
Write-Host ''
