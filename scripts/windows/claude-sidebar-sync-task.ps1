<#
Registers the scheduled task that keeps the shared Claude sidebar working after app updates.
The task runs claude-sidebar-sync.ps1 -Heal (next to this script). What -Heal does is described at the top of that
file: silent when healthy, repairs a junction an update replaced, stops and writes ALERT-claude-sidebar-sync.txt in
the data folder (default %USERPROFILE%\ClaudeSharedSidebar) on anything it does not recognize.

Default: show the task's current state only. Changes nothing and needs no admin rights.
-Apply   register (or replace) the task, then run it once and show the result.
-RunNow  run the registered task once and show the result.
-Remove  unregister the task (rollback). Files and links are not touched.
Run -Apply and -Remove from an elevated PowerShell (Run as administrator).

The task runs as the current user with logon type S4U (runs whether the user is logged on or not, no password
stored), at startup after 2 minutes and then every 10 minutes, also on battery, one instance at a time, stopped after
10 minutes. If you move this folder, run -Apply again so the task points at the new path.
#>
param([switch]$Apply, [switch]$RunNow, [switch]$Remove)
$ErrorActionPreference = 'Stop'

$TaskName = 'Claude shared sidebar'
$Script = Join-Path $PSScriptRoot 'claude-sidebar-sync.ps1'
$DataDir = Join-Path $env:USERPROFILE 'ClaudeSharedSidebar'
$Log = Join-Path $DataDir 'logs\claude-sidebar-sync.log'
$Alert = Join-Path $DataDir 'ALERT-claude-sidebar-sync.txt'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Heal' -f $Script

function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This needs an elevated PowerShell (Run as administrator).'
    }
}

function Show-Task {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) {
        "Task '$TaskName' is not registered."
        "It would run: `"$PowerShell`" $Arguments as $env:USERDOMAIN\$env:USERNAME (S4U), at startup +2 min and every 10 min."
        return
    }
    $i = Get-ScheduledTaskInfo -TaskName $TaskName
    "Task '$TaskName': state {0}, logon type {1}, user {2}" -f $t.State, $t.Principal.LogonType, $t.Principal.UserId
    "Action: {0} {1}" -f $t.Actions[0].Execute, $t.Actions[0].Arguments
    foreach ($tr in $t.Triggers) {
        $kind = $tr.CimClass.CimClassName -replace 'MSFT_Task', '' -replace 'Trigger', ''
        "Trigger: {0}, delay {1}, repeat every {2}, for {3}" -f $kind, $tr.Delay, $tr.Repetition.Interval, $(if ($tr.Repetition.Duration) { $tr.Repetition.Duration } else { 'ever' })
    }
    "Last run: {0}, result: 0x{1:X}, next run: {2}" -f $i.LastRunTime, $i.LastTaskResult, $i.NextRunTime
    if (Test-Path -LiteralPath $Alert) { "ALERT file present: $Alert"; Get-Content -LiteralPath $Alert -Encoding UTF8 }
}

function Invoke-Once {
    Start-ScheduledTask -TaskName $TaskName
    'Started. Waiting for the run to finish (up to 2 minutes)...'
    $deadline = (Get-Date).AddMinutes(2)
    Start-Sleep -Seconds 3
    while ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    Show-Task
    if (Test-Path -LiteralPath $Log) { '--- last lines of the sidebar log (a healthy run adds none):'; Get-Content -LiteralPath $Log -Tail 8 -Encoding UTF8 }
}

if ($Remove) {
    Assert-Admin
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    "Task '$TaskName' removed. No files or links were touched."
    return
}

if ($Apply) {
    Assert-Admin
    if (-not (Test-Path -LiteralPath $Script)) { throw "Script not found: $Script" }
    $action = New-ScheduledTaskAction -Execute $PowerShell -Argument $Arguments -WorkingDirectory $PSScriptRoot
    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT2M'
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $startup, $repeat -Principal $principal `
        -Settings $settings -Description 'Keeps one Claude desktop sidebar shared by the Claude accounts on this PC (repairs after app updates)' -Force | Out-Null
    "Task '$TaskName' registered."
    Invoke-Once
    return
}

if ($RunNow) { Invoke-Once; return }

Show-Task
'Nothing changed. -Apply registers and runs the task (elevated), -RunNow runs it once, -Remove unregisters it (elevated).'
