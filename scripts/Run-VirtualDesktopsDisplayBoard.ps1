# Run-VirtualDesktopsDisplayBoard.ps1
# Creates the virtual desktops, launches every panel defined in Panels.ps1, then
# hands off to the rotation script. Started by Launcher.ps1 from the "Start VDDB"
# scheduled task at logon.
#
# Panels are launched by blocking on the AHK helper, which waits for each window
# to actually appear - there are no guessed Start-Sleep values between panels.

[CmdletBinding()]
param()

. 'C:\Scripts\Panels.ps1'

$src           = 'board'
$initialSettle = 15   # seconds to let the shell settle before touching desktops

function Initialize-VirtualDesktops {
    param([int]$RequiredCount)
    $current = Get-DesktopCount
    Write-BoardLog "virtual desktops present: $current, required: $RequiredCount" 'INFO' $src
    $guard = 0
    while ($current -lt $RequiredCount -and $guard -lt 20) {
        New-Desktop | Out-Null
        Start-Sleep -Seconds 1
        $current = Get-DesktopCount
        $guard++
    }
    if ($current -lt $RequiredCount) {
        Write-BoardLog "only reached $current of $RequiredCount desktops" 'ERROR' $src
        return $false
    }
    Write-BoardLog "$current virtual desktops ready" 'OK' $src
    return $true
}

try {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Set-Content -Path $StartupMarker -Value (Get-Date -Format 's') -Force

    Write-BoardLog '=== display board starting ===' 'INFO' $src
    Write-BoardConfig $src
    Remove-OldBoardLogs $src

    Write-PanelIndex $src        # publish panel names for the rotation script's F3 picker

    Write-BoardLog "settling for $initialSettle seconds" 'INFO' $src
    Start-Sleep -Seconds $initialSettle

    Import-Module VirtualDesktop -WarningAction SilentlyContinue -ErrorAction Stop
    Write-BoardLog 'VirtualDesktop module loaded' 'OK' $src

    if (-not (Initialize-VirtualDesktops -RequiredCount $TotalDesktops)) {
        Write-BoardLog 'continuing anyway - the watchdog will retry' 'WARN' $src
    }

    $failed = 0
    foreach ($panel in ($Panels | Sort-Object { $_.Desktop })) {
        $ok = Open-OnDesktop -Desktop $panel.Desktop -Name $panel.Name `
                             -Program $panel.Program -Arguments $panel.Arguments `
                             -FullScreenKeys $panel.FullScreenKeys -Source $src
        if (-not $ok) { $failed++ }
    }

    if ($failed -gt 0) {
        Write-BoardLog "$failed of $($Panels.Count) panels failed to start - watchdog will retry" 'WARN' $src
    } else {
        Write-BoardLog "all $($Panels.Count) panels started" 'OK' $src
    }

    # Taskbar auto-hide is handled by the rotation script (it owns the F2 toggle
    # too, so keeping a second implementation here only let the two disagree).
    Write-BoardLog 'handing off to the rotation script' 'INFO' $src
    Start-Process -FilePath $AhkExe -ArgumentList ('"{0}"' -f $RotationScript) -ErrorAction Stop
    Write-BoardLog '=== display board startup complete ===' 'OK' $src
}
catch {
    Write-BoardLog "startup failed: $($_.Exception.Message)" 'ERROR' $src
    Write-BoardLog $_.ScriptStackTrace 'ERROR' $src
}
finally {
    Remove-Item $StartupMarker -Force -ErrorAction SilentlyContinue
}
