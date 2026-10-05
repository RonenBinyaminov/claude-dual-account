<#
Claude shared sidebar (Windows): one Code tab session list for every Claude account used in the Claude desktop app.

Why: the desktop app keeps the Code tab session list per account and org, in
claude-code-sessions\<account uuid>\<org uuid>\ (one local_<id>.json per session) under the app's data folder.
The conversations themselves live once in %USERPROFILE%\.claude\projects, whatever account wrote them, so a switch
of account only switches the list. This script copies the session entries of every other account folder into one
shared folder and turns those folders into junctions to it. All accounts then read and write the same list.
Unofficial: the app does not document this layout, so an app update may change it.

Default: show what it finds and what -Apply would do. Changes nothing.
-Apply     back up, merge the entries, rename each other real folder to <org>.pre-merge-<time>, put a junction in
           its place, and save the choices to config.json in the data folder.
-Heal      for the scheduled task (claude-sidebar-sync-task.ps1). Silent when healthy. When an app update put a real
           folder back in place of a junction, it merges that folder's new entries and links it again, at most 3
           repairs a day. Anything it does not recognize writes ALERT-claude-sidebar-sync.txt in the data folder and
           changes nothing.
-Rollback  remove the junctions (the link only, with cmd rmdir), rename the oldest pre-merge folder (the original
           list) back, merge the entries of later pre-merge folders into it, and turn -Heal off. Entries copied into
           the shared folder stay there.

Options:
-Primary '<account uuid>\<org uuid>'  the shared folder. Default: the folder of the account the app is signed in to
                                       when Claude runs this, else the folder with the most sessions.
-Accounts uuid1,uuid2                 which accounts to join. Default: every account folder found (at most 2).
-SessionsRoot <path>                  where claude-code-sessions is. Default: found automatically.
-DataDir <path>                       logs, backups, config.json and the alert file.
                                       Default: %USERPROFILE%\ClaudeSharedSidebar

Never remove one of these junctions with Remove-Item -Recurse in Windows PowerShell 5.1: it deletes the files of the
shared folder. This script removes junctions with cmd rmdir only.
#>
param(
    [switch]$Apply, [switch]$Heal, [switch]$Rollback,
    [string]$Primary, [string[]]$Accounts, [string]$SessionsRoot, [string]$DataDir
)
$ErrorActionPreference = 'Stop'

$MaxRepairsPerDay = 3
$StaleDays = 14
$UuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

if (-not $DataDir) { $DataDir = Join-Path $env:USERPROFILE 'ClaudeSharedSidebar' }
$LogFile = Join-Path $DataDir 'logs\claude-sidebar-sync.log'
$BackupRoot = Join-Path $DataDir 'backups'
$AlertFile = Join-Path $DataDir 'ALERT-claude-sidebar-sync.txt'
$ConfigFile = Join-Path $DataDir 'config.json'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
# Kept short: a file inside a renamed folder is close to the 260 character path limit
$AsideStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Changing = $Apply -or $Heal -or $Rollback

function Write-Log([string]$Level, [string]$Text) {
    $line = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Text
    if ($Changing) {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    if (-not $Heal) { $line }
}

function Set-Alert([string]$Text) {
    Write-Log 'ALERT' $Text
    if ($Changing) {
        if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Force $DataDir | Out-Null }
        $body = @(
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' claude-sidebar-sync stopped without changing anything.'
            $Text
            ''
            'See the state: powershell -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
            'Log: ' + $LogFile
        )
        Set-Content -LiteralPath $AlertFile -Value $body -Encoding UTF8
    }
}

function Clear-Alert {
    if ((Test-Path -LiteralPath $AlertFile) -and $Changing) {
        Remove-Item -LiteralPath $AlertFile
        Write-Log 'INFO' 'healthy again, alert file cleared'
    }
}

function Find-SessionsRoot {
    $found = New-Object System.Collections.Generic.List[string]
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    foreach ($pkg in @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue)) {
        $p = Join-Path $pkg.FullName 'LocalCache\Roaming\Claude\claude-code-sessions'
        if (Test-Path -LiteralPath $p) { $found.Add($p) }
    }
    if ($found.Count -eq 0) {
        # A classic (non-Store) install keeps its data in %APPDATA%\Claude
        $p = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
        if (Test-Path -LiteralPath $p) { $found.Add($p) }
    }
    if ($found.Count -ne 1) { return $null }
    return $found[0]
}

function Get-Combo([string]$Root, [string]$Account, [string]$Org) {
    $path = Join-Path (Join-Path $Root $Account) $Org
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    $state = 'missing'
    $target = $null
    if ($item) {
        if ($item.LinkType -eq 'Junction') { $state = 'junction'; $target = @($item.Target)[0] }
        elseif ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $state = 'other-link'; $target = @($item.Target)[0] }
        else { $state = 'folder' }
    }
    $count = 0
    if ($state -eq 'folder') { $count = @(Get-ChildItem -LiteralPath $path -File -Filter 'local_*.json').Count }
    [pscustomobject]@{ Account = $Account; Org = $Org; Key = "$Account\$Org"; Path = $path; State = $state; Target = $target; Sessions = $count }
}

function Get-FoundCombos([string]$Root) {
    foreach ($a in @(Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object { $_.Name -match $UuidPattern })) {
        foreach ($o in @(Get-ChildItem -LiteralPath $a.FullName -Directory -Force | Where-Object { $_.Name -match $UuidPattern })) {
            Get-Combo $Root $a.Name $o.Name
        }
    }
}

function Test-SamePath([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    # A junction target can come back with the NT prefix \??\
    $A = $A -replace '^\\\?\?\\', ''
    $B = $B -replace '^\\\?\?\\', ''
    return ($A.TrimEnd('\') -ieq $B.TrimEnd('\'))
}

function Get-Entries([string]$Path) {
    @(Get-ChildItem -LiteralPath $Path -File -Force | Where-Object { $_.Name -like 'local_*.json' -or $_.Name -like 'deleted_*' })
}

# Copies session entries (local_<id>.json and deleted_<id> markers) that the shared folder lacks, or holds in an
# older copy. Other files (archived index, backlog, scheduled tasks) stay as the shared folder has them.
function Merge-Entries([string]$From, [string]$To, [bool]$Write) {
    $copied = New-Object System.Collections.Generic.List[string]
    $newer = 0
    $same = 0
    foreach ($f in (Get-Entries $From)) {
        $dest = Join-Path $To $f.Name
        if (-not (Test-Path -LiteralPath $dest)) {
            if ($Write) { Copy-Item -LiteralPath $f.FullName -Destination $dest }
            $copied.Add($f.Name)
        }
        elseif ($f.LastWriteTimeUtc -gt (Get-Item -LiteralPath $dest).LastWriteTimeUtc) {
            if ($Write) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force }
            $copied.Add($f.Name)
            $newer++
        }
        else { $same++ }
    }
    $others = @(Get-ChildItem -LiteralPath $From -Force |
        Where-Object { $_.Name -notlike 'local_*.json' -and $_.Name -notlike 'deleted_*' } | ForEach-Object { $_.Name })
    [pscustomobject]@{ Copied = $copied; Newer = $newer; Same = $same; Others = $others }
}

function Backup-Folder([string]$Path, [string]$Name) {
    $dest = Join-Path (Join-Path $BackupRoot $Stamp) $Name
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $Path -Destination $dest -Recurse
    $n = @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count
    Write-Log 'INFO' "backup $Name -> $dest ($n files)"
}

function Set-Link($Combo, [string]$SharedPath) {
    $parent = Split-Path -Parent $Combo.Path
    if ($Combo.State -eq 'folder') {
        $asideName = '{0}.pre-merge-{1}' -f $Combo.Org, $AsideStamp
        $n = 2
        while (Test-Path -LiteralPath (Join-Path $parent $asideName)) {
            $asideName = '{0}.pre-merge-{1}-{2}' -f $Combo.Org, $AsideStamp, $n
            $n++
        }
        Rename-Item -LiteralPath $Combo.Path -NewName $asideName
        Write-Log 'INFO' "renamed $($Combo.Path) -> $asideName"
    }
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    New-Item -ItemType Junction -Path $Combo.Path -Target $SharedPath | Out-Null
    Write-Log 'INFO' "junction $($Combo.Path) -> $SharedPath"
}

function Remove-Link($Combo) {
    if ($Combo.State -ne 'junction') { Write-Log 'INFO' "skip $($Combo.Path): $($Combo.State)"; return }
    & cmd.exe /c rmdir "$($Combo.Path)"
    if ($LASTEXITCODE -ne 0) { throw "rmdir failed for $($Combo.Path)" }
    Write-Log 'INFO' "junction removed $($Combo.Path)"
    # Oldest first: the first pre-merge folder is the account's original list. Later ones exist when -Heal replaced a
    # folder an update put back, so their entries are merged into the restored original.
    $aside = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Combo.Path) -Directory -Filter "$($Combo.Org).pre-merge-*" |
        Sort-Object Name)
    if ($aside.Count -gt 0) {
        Rename-Item -LiteralPath $aside[0].FullName -NewName $Combo.Org
        Write-Log 'INFO' "restored $($aside[0].Name) -> $($Combo.Org)"
        foreach ($later in @($aside | Select-Object -Skip 1)) {
            $m = Merge-Entries $later.FullName $Combo.Path $true
            Write-Log 'INFO' "merged $($m.Copied.Count) entries from $($later.Name) back into $($Combo.Org)"
        }
    }
}

function Get-RepairsToday {
    if (-not (Test-Path -LiteralPath $LogFile)) { return 0 }
    $since = (Get-Date).AddHours(-24)
    @(Get-Content -LiteralPath $LogFile -Encoding UTF8 | Where-Object {
        $_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) REPAIR ' -and [datetime]$Matches[1] -gt $since
    }).Count
}

function Save-Config([hashtable]$Values) {
    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Force $DataDir | Out-Null }
    $Values | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
}

# ---- load saved choices ----
$cfg = $null
if (Test-Path -LiteralPath $ConfigFile) { $cfg = Get-Content -Raw -LiteralPath $ConfigFile -Encoding UTF8 | ConvertFrom-Json }
if ($Heal) {
    if (-not $cfg) { Set-Alert "Not set up yet: no $ConfigFile. Run the script with -Apply first."; exit 1 }
    if ($cfg.disabled) { return }
}
if (-not $SessionsRoot -and $cfg) { $SessionsRoot = $cfg.sessionsRoot }
if (-not $SessionsRoot) { $SessionsRoot = Find-SessionsRoot }
if (-not $SessionsRoot -or -not (Test-Path -LiteralPath $SessionsRoot)) {
    Set-Alert 'No single claude-code-sessions folder found (Claude desktop app missing, reinstalled, or its storage changed). Pass -SessionsRoot if it lives somewhere else.'
    exit 1
}

# ---- rollback ----
if ($Rollback) {
    foreach ($c in @(Get-FoundCombos $SessionsRoot)) { if ($c.State -eq 'junction') { Remove-Link $c } }
    if ($cfg) {
        $cfg.disabled = $true
        $cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
    }
    Write-Log 'INFO' 'rollback done, -Heal is off, entries copied into the shared folder were kept. Remove the scheduled task too: claude-sidebar-sync-task.ps1 -Remove'
    return
}

# ---- decide accounts and the shared folder ----
$found = @(Get-FoundCombos $SessionsRoot)
$foundAccounts = @($found | ForEach-Object { $_.Account } | Sort-Object -Unique)
if (-not $Accounts -and $cfg -and -not $Apply) { $Accounts = @($cfg.accounts) }
if (-not $Accounts) { $Accounts = $foundAccounts }
$Accounts = @($Accounts | ForEach-Object { $_.ToLower() } | Sort-Object -Unique)
$activeKey = $null
if ($env:CLAUDE_CODE_ACCOUNT_UUID -and $env:CLAUDE_CODE_ORGANIZATION_UUID) {
    $activeKey = ('{0}\{1}' -f $env:CLAUDE_CODE_ACCOUNT_UUID, $env:CLAUDE_CODE_ORGANIZATION_UUID).ToLower()
}
$ours = @($found | Where-Object { $Accounts -contains $_.Account.ToLower() })
$realOurs = @($ours | Where-Object { $_.State -eq 'folder' })
if (-not $Primary -and $cfg -and -not $Apply) { $Primary = $cfg.primary }
if (-not $Primary) {
    $activeReal = @($realOurs | Where-Object { $_.Key.ToLower() -eq $activeKey })
    if ($activeReal.Count -eq 1 -and $activeReal[0].Sessions -gt 0) { $Primary = $activeReal[0].Key }
    else {
        $best = $realOurs | Sort-Object Sessions -Descending | Select-Object -First 1
        if ($best) { $Primary = $best.Key }
    }
}
if (-not $Primary) { Set-Alert 'No account folder with sessions found. Sign in to each account in the app at least once.'; exit 1 }
$pa = ($Primary -split '\\')[0]
$po = ($Primary -split '\\')[1]
$shared = Get-Combo $SessionsRoot $pa $po
$orgs = @(@($ours | ForEach-Object { $_.Org }) + @($po) | ForEach-Object { $_.ToLower() } | Sort-Object -Unique)
if ($cfg -and -not $Apply) { $orgs = @(@($orgs) + @($cfg.orgs) | ForEach-Object { $_.ToLower() } | Sort-Object -Unique) }
$combos = @(foreach ($a in $Accounts) {
        foreach ($o in $orgs) {
            if (-not ($a -ieq $pa -and $o -ieq $po)) {
                $existing = @($found | Where-Object { $_.Account -ieq $a -and $_.Org -ieq $o })
                if ($existing.Count -gt 0) { $existing[0] } else { Get-Combo $SessionsRoot $a $o }
            }
        }
    })
$foreign = @($combos | Where-Object { $_.State -eq 'other-link' -or ($_.State -eq 'junction' -and -not (Test-SamePath $_.Target $shared.Path)) })
$todo = @($combos | Where-Object { $_.State -eq 'folder' -or $_.State -eq 'missing' })
$newOrgs = @()
if ($cfg -and $Heal) { $newOrgs = @($ours | Where-Object { @($cfg.orgs) -notcontains $_.Org.ToLower() }) }

# ---- report (default) ----
if (-not $Apply -and -not $Heal) {
    "Sessions root: $SessionsRoot"
    "Account folders found: " + ($foundAccounts -join ', ')
    if ($foundAccounts.Count -gt 2 -and -not $PSBoundParameters.ContainsKey('Accounts')) { 'More than 2 accounts found. Pass -Accounts with the two to join.' }
    if ($activeKey) { "The app is signed in to: $activeKey" } else { 'Not run from inside Claude: quit the Claude app, or keep it signed in to the shared account, before -Apply.' }
    "Shared folder: $($shared.Key) ($($shared.State), $($shared.Sessions) sessions)"
    foreach ($c in $combos) {
        "  {0}: {1}" -f $c.Key, $c.State
        if ($c.State -eq 'junction') { "    -> $($c.Target)" }
        if ($c.State -eq 'folder') {
            $m = Merge-Entries $c.Path $shared.Path $false
            "    -Apply would copy {0} entries ({1} of them newer copies), {2} already there, then link it" -f $m.Copied.Count, $m.Newer, $m.Same
            if ($m.Others.Count -gt 0) { "    kept as the shared folder has them: $($m.Others -join ', ')" }
        }
        if ($c.State -eq 'missing') { '    -Apply would create the junction' }
    }
    if ($foreign.Count -gt 0) { 'A link points somewhere else. -Apply and -Heal stop on it, check by hand.' }
    if ($shared.State -eq 'folder' -and $todo.Count -eq 0 -and $foreign.Count -eq 0) { 'Healthy: every account folder is a junction to the shared folder.' }
    'Nothing changed. -Apply merges and links, -Heal is the scheduled repair, -Rollback removes the links.'
    return
}

# ---- checks before changing anything ----
if ($Apply -and $Heal) { throw 'Use -Apply or -Heal, not both.' }
if ($Apply -and $foundAccounts.Count -gt 2 -and -not $PSBoundParameters.ContainsKey('Accounts')) {
    Set-Alert ('More than 2 account folders found (' + ($foundAccounts -join ', ') + '). Run -Apply with -Accounts and the two to join.')
    exit 1
}
if ($shared.State -ne 'folder') { Set-Alert "The shared folder $($shared.Path) is '$($shared.State)', expected a real folder."; exit 1 }
$sharedEntries = @(Get-ChildItem -LiteralPath $shared.Path -File -Filter 'local_*.json')
if ($sharedEntries.Count -eq 0) { Set-Alert 'The shared folder holds no local_*.json entries. The app may have changed its storage layout.'; exit 1 }
$newest = ($sharedEntries | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
if ($foreign.Count -gt 0) {
    Set-Alert ('An account folder is a link that does not point at the shared folder: ' + (($foreign | ForEach-Object { $_.Path }) -join ', '))
    exit 1
}
if ($Heal -and $newOrgs.Count -gt 0) {
    Set-Alert ('New org folder(s) since -Apply: ' + (($newOrgs | ForEach-Object { $_.Key }) -join ', ') + '. Run -Apply again to include them.')
    exit 1
}
if ($activeKey -and $activeKey -ne $shared.Key.ToLower() -and @($todo | Where-Object { $_.Key.ToLower() -eq $activeKey -and $_.State -eq 'folder' }).Count -gt 0) {
    Set-Alert "The app is signed in to $activeKey, whose folder would be replaced. Switch the app to the shared account ($($shared.Key)) first, or quit the app and run this from a normal PowerShell window."
    exit 1
}
if ($todo.Count -eq 0) {
    if ($Heal -and $newest -lt (Get-Date).AddDays(-$StaleDays)) {
        Set-Alert "Links are fine, but no session entry was written for $StaleDays days (newest $newest). The app may store sessions somewhere else now."
        exit 1
    }
    if ($Apply) {
        Save-Config @{ sessionsRoot = $SessionsRoot; primary = $shared.Key; accounts = $Accounts; orgs = $orgs; disabled = $false }
        Write-Log 'INFO' 'already linked, saved config.json, nothing else to do'
    }
    Clear-Alert
    return
}
if ($Heal) {
    $repairs = Get-RepairsToday
    if ($repairs -ge $MaxRepairsPerDay) {
        Set-Alert "$repairs repairs in the last 24 hours. The app keeps replacing the junction, so the script stopped repairing."
        exit 1
    }
}

# ---- apply / heal ----
Backup-Folder $shared.Path $shared.Key
foreach ($c in @($todo | Where-Object { $_.State -eq 'folder' })) { Backup-Folder $c.Path $c.Key }
$manifest = @{}
foreach ($c in $todo) {
    if ($c.State -eq 'folder') {
        $m = Merge-Entries $c.Path $shared.Path $true
        $manifest[$c.Key] = @($m.Copied)
        Write-Log 'INFO' ("merged {0} entries from {1} ({2} newer copies, {3} already there)" -f $m.Copied.Count, $c.Path, $m.Newer, $m.Same)
    }
    Set-Link $c $shared.Path
    if ($Heal) { Write-Log 'REPAIR' "relinked $($c.Path)" }
}
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path (Join-Path $BackupRoot $Stamp) 'copied-entries.json') -Encoding UTF8
if ($Apply) { Save-Config @{ sessionsRoot = $SessionsRoot; primary = $shared.Key; accounts = $Accounts; orgs = $orgs; disabled = $false } }

# ---- verify ----
$total = @(Get-ChildItem -LiteralPath $shared.Path -File -Filter 'local_*.json').Count
foreach ($c in $todo) {
    $now = Get-Combo $SessionsRoot $c.Account $c.Org
    $seen = @(Get-ChildItem -LiteralPath $now.Path -File -Filter 'local_*.json').Count
    if ($now.State -ne 'junction' -or -not (Test-SamePath $now.Target $shared.Path) -or $seen -ne $total) {
        Set-Alert "Verification failed for $($now.Path): state $($now.State), sees $seen of $total entries."
        exit 1
    }
}
Clear-Alert
Write-Log 'INFO' "done: $total session entries, shared by every account folder"
