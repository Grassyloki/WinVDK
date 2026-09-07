# DailySystemReboot.ps1
# Unattended daily reboot, invoked by the "VDDB Daily Reboot" scheduled task.
# Task Scheduler owns the timing - this script no longer runs a 24 hour countdown
# loop, which only ever fired if the process happened to survive all day.

. 'C:\Scripts\Panels.ps1'

# A hold set with F3 is meant to keep one panel up untouched, so the nightly
# reboot stands down until it expires. A 'forever' hold suspends it indefinitely -
# release the hold with F2 or F3 to let the board resume rebooting.
$hold = Get-ActiveHold
if ($hold) {
    $when = if ($hold.Forever) { 'until released' } else { "until $($hold.Until.ToString('yyyy-MM-dd HH:mm'))" }
    Write-BoardLog "desktop $($hold.Desktop) is held $when - skipping tonight's reboot" 'WARN' 'reboot'
    return
}

Write-BoardLog 'daily scheduled reboot - restarting now' 'INFO' 'reboot'
Start-Sleep -Seconds 5
Restart-Computer -Force
