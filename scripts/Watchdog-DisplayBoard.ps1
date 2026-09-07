# Watchdog-DisplayBoard.ps1
# Runs ONE health-check pass over the display board and exits. Task Scheduler
# supervises it (repeat every 5 minutes), so the watchdog itself cannot be the
# thing that silently dies.
#
# Checks, in order:
#   1. the expected number of virtual desktops still exists
#   2. the rotation script is running AND its heartbeat is fresh
#   3. every panel desktop still has a window from its expected process
#
# Must run in the interactive session - a process started from an SSH session
# lands in Session 0 and can neither see nor create windows on the display.

[CmdletBinding()]
param()

. 'C:\Scripts\Panels.ps1'

$src = 'watchdog'

try {
    # --- skip while the machine is still booting -----------------------------
    # The launch task and this one can both fire in the same second after a
    # reboot, before Run-VirtualDesktopsDisplayBoard.ps1 has written its startup
    # marker. Uptime is the one signal that is already true at that moment.
    $uptime = [int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds
    if ($uptime -lt $BootGraceSec) {
        Write-BoardLog "system up only ${uptime}s - letting the board finish starting" 'INFO' $src
        return
    }

    # --- skip while the board is still coming up -----------------------------
    if (Test-Path $StartupMarker) {
        $age = ((Get-Date) - (Get-Item $StartupMarker).LastWriteTime).TotalSeconds
        if ($age -lt $StartupGraceSec) {
            Write-BoardLog 'board is still starting up - skipping this pass' 'INFO' $src
            return
        }
        Write-BoardLog "startup marker is $([int]$age)s old - treating as stale" 'WARN' $src
        Remove-Item $StartupMarker -Force -ErrorAction SilentlyContinue
    }

    Import-Module VirtualDesktop -WarningAction SilentlyContinue -ErrorAction Stop
    Write-PanelIndex $src        # keep the F3 picker's names in step with the manifest

    # --- 1. virtual desktops -------------------------------------------------
    $count = Get-DesktopCount
    if ($count -lt $TotalDesktops) {
        Write-BoardLog "only $count of $TotalDesktops desktops exist - recreating" 'WARN' $src
        $guard = 0
        while ((Get-DesktopCount) -lt $TotalDesktops -and $guard -lt 20) {
            New-Desktop | Out-Null; Start-Sleep -Seconds 1; $guard++
        }
        Write-BoardLog "desktop count now $(Get-DesktopCount)" 'OK' $src
    }

    # --- 2. rotation alive and ticking ---------------------------------------
    $rotation = Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkeyU64.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like '*DesktopSwitchingFunctions.ahk*' }

    $heartbeatAge = $null
    if (Test-Path $HeartbeatFile) {
        $heartbeatAge = [int]((Get-Date) - (Get-Item $HeartbeatFile).LastWriteTime).TotalSeconds
    }

    $rotationHealthy = ($null -ne $rotation) -and
                       ($null -ne $heartbeatAge) -and
                       ($heartbeatAge -lt $HeartbeatMaxAgeSec)

    if ($rotationHealthy) {
        Write-BoardLog "rotation healthy (heartbeat ${heartbeatAge}s old)" 'INFO' $src
    }
    else {
        if ($null -eq $rotation) {
            Write-BoardLog 'rotation script is not running - restarting it' 'WARN' $src
        } else {
            $shown = if ($null -eq $heartbeatAge) { 'missing' } else { "${heartbeatAge}s old" }
            Write-BoardLog "rotation is running but its heartbeat is $shown - restarting it" 'WARN' $src
            foreach ($p in $rotation) {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
            }
            Start-Sleep -Seconds 2
        }
        Start-Process -FilePath $AhkExe -ArgumentList ('"{0}"' -f $RotationScript) -ErrorAction Stop
        Write-BoardLog 'rotation restarted' 'OK' $src
    }

    # --- 3. panels still on screen -------------------------------------------
    $occupancy = Get-DesktopOccupancy -Source $src
    $missing = @()
    $notFull = @()
    foreach ($panel in ($Panels | Sort-Object { $_.Desktop })) {
        $entries = $occupancy[[int]$panel.Desktop]
        $match = $entries | Where-Object { $_.ProcessName -eq $panel.ProcessName } | Select-Object -First 1
        if (-not $match) {
            $missing += $panel
            continue
        }
        if ($panel.FullScreenKeys -and -not $match.FullScreen) {
            # The window is there but windowed - MyRadar sometimes ignores the
            # fullscreen key during a cold boot while it is still starting up.
            # Repair it in place rather than relaunching and losing its state.
            Write-BoardLog ("desktop {0} '{1}' present but {2}x{3} at {4},{5}" -f `
                $panel.Desktop, $panel.Name, $match.Width, $match.Height, $match.X, $match.Y) 'WARN' $src
            $notFull += [pscustomobject]@{ Panel = $panel; Handle = $match.Handle }
        } else {
            Write-BoardLog "desktop $($panel.Desktop) '$($panel.Name)' ok" 'INFO' $src
        }
    }

    foreach ($item in $notFull) {
        Repair-PanelFullScreen -Desktop $item.Panel.Desktop -Name $item.Panel.Name `
                               -FullScreenKeys $item.Panel.FullScreenKeys -Hwnd $item.Handle -Source $src | Out-Null
    }

    if ($missing.Count -eq 0) {
        if ($notFull.Count -eq 0) { Write-BoardLog 'all panels present and full screen' 'OK' $src }
    }
    elseif ($missing.Count -eq $Panels.Count) {
        # Every single panel missing is far more likely to be a window/desktop
        # detection failure than five simultaneous crashes. Relaunching all of
        # them every 5 minutes would thrash the display, so shout instead and
        # let the daily reboot be the backstop.
        Write-BoardLog 'every panel looks missing - suspecting a detection failure, not relaunching' 'ERROR' $src
    }
    else {
        foreach ($panel in $missing) {
            Write-BoardLog "desktop $($panel.Desktop) '$($panel.Name)' is missing - relaunching" 'WARN' $src
            Open-OnDesktop -Desktop $panel.Desktop -Name $panel.Name `
                           -Program $panel.Program -Arguments $panel.Arguments `
                           -FullScreenKeys $panel.FullScreenKeys -Source $src | Out-Null
        }
    }

    Remove-OldBoardLogs $src
}
catch {
    Write-BoardLog "watchdog pass failed: $($_.Exception.Message)" 'ERROR' $src
}
