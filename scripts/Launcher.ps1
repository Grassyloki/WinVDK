# Launcher.ps1
# Entry point for the "Start VDDB" scheduled task. Kept deliberately thin: it
# only starts the display board script and returns, so a slow startup never
# holds the task open.

[CmdletBinding()]
param(
    [string]$WorkingDirectory = 'C:\Scripts'
)

Set-Location $WorkingDirectory

$mainScript = Join-Path $WorkingDirectory 'Run-VirtualDesktopsDisplayBoard.ps1'
if (-not (Test-Path $mainScript)) {
    Write-Host "ERROR: $mainScript not found" -ForegroundColor Red
    exit 1
}

Write-Host "Starting display board: $mainScript" -ForegroundColor Cyan
Start-Process powershell.exe -ArgumentList @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', ('"{0}"' -f $mainScript)
)
Write-Host 'Launcher done.' -ForegroundColor Green
