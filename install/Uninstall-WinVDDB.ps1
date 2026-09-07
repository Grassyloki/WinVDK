<#
.SYNOPSIS
    Removes the WinVDDB scheduled tasks, and optionally the installed scripts.

.DESCRIPTION
    Run from an elevated PowerShell:

        .\install\Uninstall-WinVDDB.ps1                 # unregister the tasks only
        .\install\Uninstall-WinVDDB.ps1 -RemoveFiles    # also delete C:\Scripts

    Nothing is deleted without -RemoveFiles, and -RemoveFiles asks for
    confirmation before it touches anything. The VirtualDesktop PowerShell
    module and AutoHotkey are left installed - they are ordinary packages and
    may be in use by something else.

.PARAMETER InstallPath
    Where the board scripts were installed.

.PARAMETER RemoveFiles
    Also delete the install folder, including its logs and state files.

.PARAMETER StopBoard
    Stop the rotation script and any kiosk browser windows it launched. Only
    meaningful when run in the interactive session on the display itself.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InstallPath = 'C:\Scripts',
    [switch]$RemoveFiles,
    [switch]$StopBoard
)

$ErrorActionPreference = 'Stop'

function Info { param($m) Write-Host $m -ForegroundColor Cyan }
function Ok   { param($m) Write-Host $m -ForegroundColor Green }
function Warn { param($m) Write-Host $m -ForegroundColor Yellow }
function Fail { param($m) Write-Host $m -ForegroundColor Red }

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'This must run from an elevated PowerShell (Run as administrator).'
    exit 1
}

foreach ($task in 'Start VDDB', 'VDDB Watchdog', 'VDDB Daily Reboot') {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
        Ok "unregistered '$task'"
    } else {
        Info "'$task' was not registered"
    }
}

if ($StopBoard) {
    # Only the rotation script is stopped by name; panel windows are left to the
    # operator, since "kill every firefox" is rarely what someone wants.
    Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkeyU64.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*DesktopSwitchingFunctions*' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Ok "stopped rotation script (pid $($_.ProcessId))"
        }
    Warn 'Panel windows were left running - close them by hand, or reboot.'
}

if ($RemoveFiles) {
    if (Test-Path $InstallPath) {
        if ($PSCmdlet.ShouldProcess($InstallPath, 'Delete the WinVDDB install folder and all its logs')) {
            Remove-Item $InstallPath -Recurse -Force
            Ok "removed $InstallPath"
        }
    } else {
        Info "$InstallPath does not exist"
    }
} else {
    Info "$InstallPath was left in place (pass -RemoveFiles to delete it)."
}

Ok 'WinVDDB uninstalled.'
