#Requires -Version 5.1
<#
.SYNOPSIS
  Finds Enshrouded saves on this PC and restores one backup timeslot.

.DESCRIPTION
  Double-click "Restore Enshrouded Save.bat".
  The window lists every world, character, and global save it finds, with each
  backup's date and size. Restoring copies the current file into a
  rollback-safety folder, then puts the chosen backup back in place.

  -List                  Print what was found and exit.
  -Path <folder>         Search only this folder (and its children).
  -Choose <n> -Slot <n>  Restore without the window. Numbers match -List.
  -Force                 Skip the YES prompt. Still refuses to run if the game is open.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$List,
    [int]$Choose = 0,
    [int]$Slot = 0,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SkipDirectoryNames = @('backup', 'migrated', 'caches')

function Get-NormalizedPath {
    param([string]$LiteralPath)
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath($LiteralPath)
    } catch {
        return $null
    }
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Format-When {
    param([datetime]$Time)
    return $Time.ToString('MMM d, yyyy h:mm:ss tt')
}

function Test-EnshroudedRunning {
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'enshrouded*' })
        return ($procs.Count -gt 0)
    } catch {
        return $false
    }
}

function Get-SteamInstallPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($key in @(
            'HKCU:\Software\Valve\Steam',
            'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
            'HKLM:\SOFTWARE\Valve\Steam'
        )) {
        try {
            $item = Get-ItemProperty -Path $key -ErrorAction Stop
        } catch {
            continue
        }
        foreach ($name in @('SteamPath', 'InstallPath')) {
            $prop = $item.PSObject.Properties[$name]
            if ($prop -and $prop.Value) { $paths.Add([string]$prop.Value) }
        }
    }
    foreach ($candidate in @(
            $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Steam' }),
            $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Steam' }),
            $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Steam' })
        )) {
        if ($candidate) { $paths.Add([string]$candidate) }
    }

    $unique = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($candidate in $paths) {
        $full = Get-NormalizedPath $candidate
        if (-not $full) { continue }
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $unique.Add($full)
    }
    return $unique
}

function Get-SteamLibraryPaths {
    param([string]$SteamRoot)
    $libs = New-Object System.Collections.Generic.List[string]
    $libs.Add($SteamRoot)
    $vdf = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $vdf)) { return $libs }
    $text = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return $libs }
    foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
        $raw = $match.Groups[1].Value -replace '\\\\', '\'
        $full = Get-NormalizedPath $raw
        if ($full -and (Test-Path -LiteralPath $full)) { $libs.Add($full) }
    }
    return $libs
}

function Test-SaveRoot {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    $ksd = @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.ksd' -ErrorAction SilentlyContinue)
    if ($ksd.Count -gt 0) { return $true }
    $backup = Join-Path $Dir 'backup'
    if (Test-Path -LiteralPath $backup) {
        $backs = @(Get-ChildItem -LiteralPath $backup -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '\.ksd\.backup-\d+$' })
        if ($backs.Count -gt 0) { return $true }
    }
    $indexes = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '-index$' -and $_.Name -notmatch '_info-index$' })
    return ($indexes.Count -gt 0)
}

function Add-SaveRootsFrom {
    param(
        [string]$Start,
        [int]$Depth,
        [System.Collections.Generic.List[string]]$Into
    )
    $full = Get-NormalizedPath $Start
    if (-not $full) { return }
    if (-not (Test-Path -LiteralPath $full)) { return }
    if (Test-SaveRoot $full) {
        $Into.Add($full)
        return
    }
    if ($Depth -le 0) { return }
    Get-ChildItem -LiteralPath $full -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($script:SkipDirectoryNames -contains $_.Name) { return }
        if ($_.Name -like 'rollback-safety-*') { return }
        Add-SaveRootsFrom -Start $_.FullName -Depth ($Depth - 1) -Into $Into
    }
}

function Get-SearchStarts {
    param([string]$OnlyPath, [string]$AlsoPath)
    $starts = New-Object System.Collections.Generic.List[object]
    if ($OnlyPath) {
        $starts.Add([pscustomobject]@{ Path = $OnlyPath; Depth = 4 })
        return $starts
    }
    if ($AlsoPath) {
        $starts.Add([pscustomobject]@{ Path = $AlsoPath; Depth = 4 })
    }

    $saved = Join-Path $env:USERPROFILE 'Saved Games'
    $starts.Add([pscustomobject]@{ Path = (Join-Path $saved 'keen games'); Depth = 3 })
    $starts.Add([pscustomobject]@{ Path = (Join-Path $saved 'Enshrouded'); Depth = 2 })

    foreach ($steam in (Get-SteamInstallPaths)) {
        $userdata = Join-Path $steam 'userdata'
        if (Test-Path -LiteralPath $userdata) {
            Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $remote = Join-Path $_.FullName '1203620\remote'
                $starts.Add([pscustomobject]@{ Path = $remote; Depth = 1 })
            }
        }
        foreach ($lib in (Get-SteamLibraryPaths -SteamRoot $steam)) {
            $pfxSaved = Join-Path $lib 'steamapps\compatdata\1203620\pfx\drive_c\users\steamuser\Saved Games'
            $starts.Add([pscustomobject]@{ Path = (Join-Path $pfxSaved 'keen games'); Depth = 3 })
            $starts.Add([pscustomobject]@{ Path = (Join-Path $pfxSaved 'Enshrouded'); Depth = 2 })
        }
    }

    if ($env:HOME) {
        foreach ($rel in @(
                '.steam/steam/userdata',
                '.steam/root/userdata',
                '.local/share/Steam/userdata',
                '.var/app/com.valvesoftware.Steam/.local/share/Steam/userdata'
            )) {
            $userdata = Join-Path $env:HOME $rel
            if (-not (Test-Path -LiteralPath $userdata)) { continue }
            Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $remote = Join-Path $_.FullName '1203620/remote'
                $starts.Add([pscustomobject]@{ Path = $remote; Depth = 1 })
            }
        }
    }
    return $starts
}

function Get-SaveRoots {
    param([string]$OnlyPath, [string]$AlsoPath)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($start in (Get-SearchStarts -OnlyPath $OnlyPath -AlsoPath $AlsoPath)) {
        Add-SaveRootsFrom -Start $start.Path -Depth $start.Depth -Into $found
    }
    $unique = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($candidate in $found) {
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $unique.Add($candidate)
    }
    return $unique
}

function Get-RootInfo {
    param([string]$Root)
    $lower = $Root.ToLowerInvariant()
    $steam = [regex]::Match($lower, '[\\/]userdata[\\/](\d+)[\\/]1203620[\\/]remote')
    if ($steam.Success) {
        return [pscustomobject]@{ Kind = 'steam'; Account = $steam.Groups[1].Value; Place = ('Steam Cloud (account {0})' -f $steam.Groups[1].Value) }
    }
    if ($lower -match 'compatdata[\\/]1203620') {
        return [pscustomobject]@{ Kind = 'proton'; Account = $null; Place = 'Proton save' }
    }
    if ($lower -match 'keen games') {
        return [pscustomobject]@{ Kind = 'local'; Account = $null; Place = 'Local save' }
    }
    return [pscustomobject]@{ Kind = 'folder'; Account = $null; Place = 'Save folder' }
}

function Get-FamilyTitle {
    param([string]$Name)
    switch -Regex ($Name) {
        '^world0$' { return 'World (world0.ksd)' }
        '^world(\d+)$' { return ('Extra world (world{0}.ksd)' -f $Matches[1]) }
        '^character\d*$' { return ('Character ({0}.ksd)' -f $Name) }
        '^characters$' { return 'Characters' }
        '^global$' { return 'Global data (global.ksd)' }
        default { return $Name }
    }
}

function Get-FamilyRank {
    param([string]$Name)
    switch -Regex ($Name) {
        '^world0$' { return 0 }
        '^world\d+$' { return 1 }
        '^character\d*$' { return 2 }
        '^characters$' { return 2 }
        '^global$' { return 3 }
        default { return 4 }
    }
}

function Get-PlaceRank {
    param([string]$Kind)
    switch ($Kind) {
        'steam' { return 0 }
        'proton' { return 1 }
        'local' { return 2 }
        default { return 3 }
    }
}

function Get-FileSha1 {
    param([string]$FilePath)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'ReadWrite')
        return ([BitConverter]::ToString($sha1.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } catch {
        return $null
    } finally {
        if ($stream) { $stream.Dispose() }
        $sha1.Dispose()
    }
}

function New-Slot {
    param(
        [int]$SlotNumber,
        [string]$FilePath,
        [datetime]$Time,
        [long]$Length,
        [bool]$IsCurrent
    )
    $note = ''
    if ($IsCurrent) { $note = 'Same as the current save' }
    elseif ($Length -lt 1024) { $note = 'Very small file' }
    return [pscustomobject]@{
        Slot      = $SlotNumber
        Path      = $FilePath
        Time      = $Time
        Length    = $Length
        IsCurrent = $IsCurrent
        Note      = $note
    }
}

function Get-KsdGroups {
    param([string]$Root, $RootInfo)
    $families = @{}
    Get-ChildItem -LiteralPath $Root -File -Filter '*.ksd' -ErrorAction SilentlyContinue | ForEach-Object {
        $families[$_.BaseName] = @{ Live = $_; Copies = New-Object System.Collections.Generic.List[object] }
    }
    $backupDir = Join-Path $Root 'backup'
    if (Test-Path -LiteralPath $backupDir) {
        Get-ChildItem -LiteralPath $backupDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            $match = [regex]::Match($_.Name, '^(?<base>.+)\.ksd\.backup-(?<slot>\d+)$')
            if (-not $match.Success) { return }
            $base = $match.Groups['base'].Value
            if (-not $families.ContainsKey($base)) {
                $families[$base] = @{ Live = $null; Copies = New-Object System.Collections.Generic.List[object] }
            }
            $families[$base].Copies.Add([pscustomobject]@{
                    Slot   = [int]$match.Groups['slot'].Value
                    Path   = $_.FullName
                    Time   = $_.LastWriteTime
                    Length = [long]$_.Length
                })
        }
    }

    $groups = @()
    foreach ($name in @($families.Keys)) {
        $fam = $families[$name]
        $live = $fam.Live
        $currentTime = $null
        $currentLength = $null
        $livePath = Join-Path $Root ($name + '.ksd')
        if ($live) {
            $currentTime = $live.LastWriteTime
            $currentLength = [long]$live.Length
            $livePath = $live.FullName
        }
        $slots = @()
        $meaningful = $false
        $liveHash = $null
        if ($live -and $currentLength -ge 1024) { $meaningful = $true }
        if ($live) { $liveHash = Get-FileSha1 -FilePath $live.FullName }
        foreach ($copy in @($fam.Copies | Sort-Object Time -Descending)) {
            if ($copy.Length -ge 1024) { $meaningful = $true }
            $same = $false
            if ($liveHash) {
                $copyHash = Get-FileSha1 -FilePath $copy.Path
                if ($copyHash -and $copyHash -eq $liveHash) { $same = $true }
            } elseif ($live -and $currentTime -and $copy.Length -eq $currentLength) {
                $same = $currentTime.ToString('yyyyMMddHHmmss') -eq $copy.Time.ToString('yyyyMMddHHmmss')
            }
            $slots += New-Slot -SlotNumber $copy.Slot -FilePath $copy.Path -Time $copy.Time -Length $copy.Length -IsCurrent $same
        }
        if (-not $meaningful -and $name -ne 'world0') { continue }
        $when = if ($currentTime) { Format-When $currentTime } else { 'missing' }
        $size = if ($null -ne $currentLength) { Format-FileSize $currentLength } else { 'missing' }
        $groups += [pscustomobject]@{
            Name          = $name
            Title         = (Get-FamilyTitle $name)
            Place         = $RootInfo.Place
            RootKind      = $RootInfo.Kind
            Root          = $Root
            Mode          = 'ksd'
            LivePath      = $livePath
            LiveExists    = [bool]$live
            IndexPath     = $null
            CurrentTime   = $currentTime
            CurrentLength = $currentLength
            Slots         = $slots
            MenuLabel     = ('{0}  -  {1}  -  current {2}, {3}' -f $RootInfo.Place, (Get-FamilyTitle $name), $when, $size)
        }
    }
    return $groups
}

function Read-IndexLatest {
    param([string]$IndexPath)
    $text = [System.IO.File]::ReadAllText($IndexPath)
    $match = [regex]::Match($text, '"latest"\s*:\s*(\d+)')
    if (-not $match.Success) { return $null }
    return [int]$match.Groups[1].Value
}

function Get-IndexGroups {
    param([string]$Root, $RootInfo)
    $groups = @()
    $indexes = @(Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '-index$' -and $_.Name -notmatch '_info-index$'
        })
    foreach ($index in $indexes) {
        $match = [regex]::Match($index.Name, '^(?<id>.+)-index$')
        if (-not $match.Success) { continue }
        $id = $match.Groups['id'].Value
        $latest = Read-IndexLatest -IndexPath $index.FullName
        if ($null -eq $latest) { continue }

        $slots = @()
        $slotFiles = @([pscustomobject]@{ Slot = 0; Path = (Join-Path $Root $id) })
        1..9 | ForEach-Object {
            $slotFiles += [pscustomobject]@{ Slot = $_; Path = (Join-Path $Root ('{0}-{1}' -f $id, $_)) }
        }
        foreach ($slotFile in $slotFiles) {
            if (-not (Test-Path -LiteralPath $slotFile.Path)) { continue }
            $item = Get-Item -LiteralPath $slotFile.Path
            $slots += New-Slot -SlotNumber $slotFile.Slot -FilePath $item.FullName -Time $item.LastWriteTime -Length ([long]$item.Length) -IsCurrent ($slotFile.Slot -eq $latest)
        }
        $slots = @($slots | Sort-Object Time -Descending)
        $title = if ($id -eq 'characters') { 'Characters (older format)' } else { ('World {0} (older format)' -f $id) }
        $groups += [pscustomobject]@{
            Name          = $id
            Title         = $title
            Place         = $RootInfo.Place
            RootKind      = $RootInfo.Kind
            Root          = $Root
            Mode          = 'index'
            LivePath      = $index.FullName
            LiveExists    = $true
            IndexPath     = $index.FullName
            CurrentTime   = $index.LastWriteTime
            CurrentLength = [long]$index.Length
            Slots         = $slots
            MenuLabel     = ('{0}  -  {1}  -  loaded slot {2}' -f $RootInfo.Place, $title, $latest)
        }
    }
    return $groups
}

function Get-MigratedNotes {
    param([string[]]$Roots, [string]$OnlyPath)
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not $OnlyPath) {
        $saved = Join-Path $env:USERPROFILE 'Saved Games'
        $candidates.Add((Join-Path $saved 'Enshrouded\migrated'))
        $candidates.Add((Join-Path $saved 'keen games\Enshrouded\migrated'))
    }
    foreach ($root in $Roots) {
        $candidates.Add((Join-Path $root 'migrated'))
        $parent = Split-Path -Parent $root
        if ($parent) { $candidates.Add((Join-Path $parent 'migrated')) }
    }
    $notes = @()
    $seen = @{}
    foreach ($candidate in $candidates) {
        $full = Get-NormalizedPath $candidate
        if (-not $full) { continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (Test-Path -LiteralPath $full) {
            $notes += 'An older migrated folder was found. Version 1.0 does not load it, so those files are not listed.'
            break
        }
    }
    return $notes
}

function Find-SaveGroups {
    param([string]$OnlyPath, [string]$AlsoPath)
    $roots = @(Get-SaveRoots -OnlyPath $OnlyPath -AlsoPath $AlsoPath)
    $groups = @()
    foreach ($root in $roots) {
        $info = Get-RootInfo -Root $root
        $groups += @(Get-KsdGroups -Root $root -RootInfo $info)
        $groups += @(Get-IndexGroups -Root $root -RootInfo $info)
    }
    $groups = @($groups | Sort-Object @{ Expression = { Get-PlaceRank $_.RootKind } }, @{ Expression = { Get-FamilyRank $_.Name } }, Root, Name)
    $notes = @(Get-MigratedNotes -Roots $roots -OnlyPath $OnlyPath)
    $steamGroups = @($groups | Where-Object { $_.RootKind -eq 'steam' -or $_.RootKind -eq 'proton' })
    if (-not $OnlyPath -and -not $AlsoPath -and $steamGroups.Count -gt 0) {
        $groups = $steamGroups
        $notes = @('These are the Steam Cloud saves. The Keen Games folder is a separate local world, so it is not listed.') + @($notes)
    }
    return [pscustomobject]@{
        Groups = $groups
        Notes  = $notes
        Roots  = $roots
    }
}

function Invoke-RestoreSlot {
    param($Group, $SlotInfo)
    if (Test-EnshroudedRunning) {
        throw 'Enshrouded is still running. Close the game, then restore.'
    }
    if ($SlotInfo.IsCurrent) {
        throw 'That timeslot is already the current save.'
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safety = Join-Path $Group.Root ('rollback-safety-' + $stamp)
    New-Item -ItemType Directory -Path $safety | Out-Null

    if ($Group.Mode -eq 'ksd') {
        if ($Group.LiveExists -and (Test-Path -LiteralPath $Group.LivePath)) {
            Copy-Item -LiteralPath $Group.LivePath -Destination (Join-Path $safety (Split-Path -Leaf $Group.LivePath))
        }
        Copy-Item -LiteralPath $SlotInfo.Path -Destination $Group.LivePath -Force
        $written = Get-Item -LiteralPath $Group.LivePath
        if ([long]$written.Length -ne [long]$SlotInfo.Length) {
            throw 'The restored file size does not match the backup. The previous file is in the safety folder.'
        }
        if ($Group.RootKind -eq 'steam') {
            # Keep the backup's old time and Steam Cloud treats the cloud copy as newer and downloads it back.
            (Get-Item -LiteralPath $Group.LivePath).LastWriteTime = Get-Date
        }
    } else {
        $indexLeaf = Split-Path -Leaf $Group.IndexPath
        Copy-Item -LiteralPath $Group.IndexPath -Destination (Join-Path $safety $indexLeaf)
        $text = [System.IO.File]::ReadAllText($Group.IndexPath)
        $updated = [regex]::Replace($text, '"latest"\s*:\s*\d+', ('"latest": {0}' -f $SlotInfo.Slot), 1)
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Group.IndexPath, $updated, $utf8)
        $check = Read-IndexLatest -IndexPath $Group.IndexPath
        if ($check -ne $SlotInfo.Slot) {
            throw 'The index file did not update. The previous index is in the safety folder.'
        }
    }
    return $safety
}

function Write-Discovery {
    param($Discovery)
    if ($Discovery.Notes.Count -gt 0) {
        foreach ($note in $Discovery.Notes) { Write-Output $note }
        Write-Output ''
    }
    if ($Discovery.Groups.Count -eq 0) {
        Write-Output 'No Enshrouded saves were found.'
        return
    }
    $groupNumber = 1
    foreach ($group in $Discovery.Groups) {
        Write-Output ('{0}) {1}' -f $groupNumber, $group.MenuLabel)
        Write-Output ('   {0}' -f $group.Root)
        if ($group.Slots.Count -eq 0) {
            Write-Output '   No older copies.'
        }
        $slotNumber = 1
        foreach ($slotInfo in $group.Slots) {
            $note = ''
            if ($slotInfo.Note) { $note = '  [' + $slotInfo.Note + ']' }
            $slotLabel = if ($group.Mode -eq 'index') { 'slot-{0}' -f $slotInfo.Slot } else { 'backup-{0}' -f $slotInfo.Slot }
            Write-Output ('   {0}. {1}   {2}   {3}{4}' -f $slotNumber, (Format-When $slotInfo.Time), (Format-FileSize $slotInfo.Length), $slotLabel, $note)
            $slotNumber++
        }
        Write-Output ''
        $groupNumber++
    }
}

function Restore-ChosenSlot {
    param($Discovery, [int]$GroupNumber, [int]$SlotNumber, [bool]$SkipPrompt)
    if ($GroupNumber -lt 1 -or $GroupNumber -gt $Discovery.Groups.Count) {
        throw "Choose must be from 1 to $($Discovery.Groups.Count)."
    }
    $group = $Discovery.Groups[$GroupNumber - 1]
    if ($SlotNumber -lt 1 -or $SlotNumber -gt @($group.Slots).Count) {
        throw "Slot must be from 1 to $(@($group.Slots).Count) for that save."
    }
    $slotInfo = @($group.Slots)[$SlotNumber - 1]
    if (-not $SkipPrompt) {
        Write-Output ('Restore {0} to {1} ({2})?' -f $group.Title, (Format-When $slotInfo.Time), (Format-FileSize $slotInfo.Length))
        $answer = Read-Host 'Type YES to continue'
        if ($answer -ne 'YES') {
            Write-Output 'Cancelled.'
            return
        }
    }
    $safety = Invoke-RestoreSlot -Group $group -SlotInfo $slotInfo
    Write-Output ('Restored {0} to {1}.' -f $group.Title, (Format-When $slotInfo.Time))
    Write-Output ('Previous file saved in {0}' -f $safety)
    if ($group.RootKind -eq 'steam') {
        Write-Output 'Restart Steam before you open Enshrouded. If Steam asks which files to use, choose the files on this PC.'
    }
}

function Update-RestoreButton {
    $enabled = $false
    if ($script:ui.List.SelectedItems.Count -eq 1) {
        $enabled = -not [bool]$script:ui.List.SelectedItems[0].Tag.IsCurrent
    }
    $script:ui.Restore.Enabled = $enabled
}

function Update-Hint {
    $index = $script:ui.Combo.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:groups.Count) {
        $script:ui.Path.Text = ''
        $script:ui.Hint.Text = ''
        return
    }
    $group = $script:groups[$index]
    $script:ui.Path.Text = $group.Root
    if ($group.RootKind -eq 'steam' -and $group.Name -eq 'world0') {
        $script:ui.Hint.Text = 'Steam Cloud world. Pick the time to put back. Restart Steam before you play, and if Steam asks, keep the files on this PC.'
    } elseif ($group.RootKind -eq 'local' -and $group.Name -eq 'world0') {
        $script:ui.Hint.Text = 'This is a local world folder, separate from Steam Cloud.'
    } elseif ($group.Name -like 'character*') {
        $script:ui.Hint.Text = 'This is the character: level, skills, gear, and inventory. It is separate from the world.'
    } elseif ($group.Name -eq 'global') {
        $script:ui.Hint.Text = 'This is global data, not the world or the character.'
    } else {
        $script:ui.Hint.Text = 'The number in the backup name is only a slot. The time is what matters.'
    }
}

function Show-SelectedGroup {
    $script:ui.List.Items.Clear()
    $index = $script:ui.Combo.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:groups.Count) {
        Update-RestoreButton
        Update-Hint
        return
    }
    $group = $script:groups[$index]
    foreach ($slotInfo in @($group.Slots)) {
        $item = New-Object System.Windows.Forms.ListViewItem((Format-When $slotInfo.Time))
        [void]$item.SubItems.Add((Format-FileSize $slotInfo.Length))
        $slotLabel = if ($group.Mode -eq 'index') { 'slot-{0}' -f $slotInfo.Slot } else { 'backup-{0}' -f $slotInfo.Slot }
        [void]$item.SubItems.Add($slotLabel)
        [void]$item.SubItems.Add([string]$slotInfo.Note)
        $item.Tag = $slotInfo
        if ($slotInfo.IsCurrent) { $item.ForeColor = [System.Drawing.Color]::DimGray }
        [void]$script:ui.List.Items.Add($item)
    }
    if ($script:ui.List.Items.Count -gt 0) {
        $pick = 0
        for ($i = 0; $i -lt $script:ui.List.Items.Count; $i++) {
            if (-not $script:ui.List.Items[$i].Tag.IsCurrent) { $pick = $i; break }
        }
        $script:ui.List.Items[$pick].Selected = $true
        $script:ui.List.Items[$pick].Focused = $true
    }
    Update-Hint
    Update-RestoreButton
}

function Fill-SaveCombo {
    param([string]$PreferRoot, [string]$PreferName)
    $script:ui.Combo.Items.Clear()
    foreach ($group in $script:groups) {
        [void]$script:ui.Combo.Items.Add($group.MenuLabel)
    }
    $select = 0
    if ($PreferRoot -and $PreferName) {
        for ($i = 0; $i -lt $script:groups.Count; $i++) {
            if ($script:groups[$i].Root -eq $PreferRoot -and $script:groups[$i].Name -eq $PreferName) {
                $select = $i
                break
            }
        }
    }
    if ($script:ui.Combo.Items.Count -gt 0) {
        $script:ui.Combo.SelectedIndex = $select
    } else {
        $script:ui.List.Items.Clear()
        $script:ui.Path.Text = 'No Enshrouded saves were found. Use Browse if the folder is somewhere else.'
        $script:ui.Hint.Text = ''
        Update-RestoreButton
    }
    $folderCount = @($script:groups | Select-Object -ExpandProperty Root -Unique).Count
    $script:ui.Status.Text = ('Found {0} save(s) in {1} folder(s).' -f $script:groups.Count, $folderCount)
}

function Import-Discovery {
    param($Discovery, [string]$PreferRoot, [string]$PreferName)
    $script:groups = @($Discovery.Groups)
    $noteText = ''
    if ($Discovery.Notes.Count -gt 0) { $noteText = [string]($Discovery.Notes -join '  ') }
    if (Test-EnshroudedRunning) {
        $running = 'Enshrouded is open. Close it before restoring.'
        $noteText = if ($noteText) { $running + '  ' + $noteText } else { $running }
    }
    $script:ui.Notes.Text = $noteText
    Fill-SaveCombo -PreferRoot $PreferRoot -PreferName $PreferName
}

function Start-RestoreFromWindow {
    if ($script:ui.Combo.SelectedIndex -lt 0) { return }
    if ($script:ui.List.SelectedItems.Count -ne 1) { return }
    $group = $script:groups[$script:ui.Combo.SelectedIndex]
    $slotInfo = $script:ui.List.SelectedItems[0].Tag
    if ($slotInfo.IsCurrent) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'That timeslot is already the current save. Pick an earlier time.',
            'Enshrouded save rollback')
        return
    }
    $cloud = ''
    if ($group.RootKind -eq 'steam') {
        $cloud = "`r`n`r`nThis is the Steam Cloud save. Restart Steam before you open the game. If Steam asks which files to use, choose the files on this PC."
    }
    $message = @"
Restore $($group.Title) to $(Format-When $slotInfo.Time) ($(Format-FileSize $slotInfo.Length))?

This replaces:
$($group.LivePath)

The file there now is copied into a rollback-safety folder first. The other backup copies stay where they are.$cloud
"@
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Restore this time?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $safety = Invoke-RestoreSlot -Group $group -SlotInfo $slotInfo
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not restore')
        return
    }
    $done = "Restored $($group.Title) to $(Format-When $slotInfo.Time).`r`n`r`nThe previous file is in:`r`n$safety"
    [void][System.Windows.Forms.MessageBox]::Show($done, 'Restore finished')
    $discovery = Find-SaveGroups -OnlyPath $script:onlyPath -AlsoPath $script:alsoPath
    Import-Discovery -Discovery $discovery -PreferRoot $group.Root -PreferName $group.Name
}

function Show-RestoreWindow {
    param($Discovery)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Enshrouded save rollback'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(860, 640)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 520)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $intro = New-Object System.Windows.Forms.Label
    $intro.AutoSize = $false
    $intro.Location = New-Object System.Drawing.Point(16, 12)
    $intro.Size = New-Object System.Drawing.Size(810, 58)
    $intro.Anchor = 'Top,Left,Right'
    $intro.Text = "Close Enshrouded first. This list is the Steam Cloud save, not the local Keen Games folder.`r`nPick a time, restore it, then restart Steam before you play."

    $notes = New-Object System.Windows.Forms.Label
    $notes.AutoSize = $false
    $notes.Location = New-Object System.Drawing.Point(16, 72)
    $notes.Size = New-Object System.Drawing.Size(810, 36)
    $notes.Anchor = 'Top,Left,Right'
    $notes.ForeColor = [System.Drawing.Color]::DarkRed

    $saveLabel = New-Object System.Windows.Forms.Label
    $saveLabel.Text = 'Save'
    $saveLabel.Location = New-Object System.Drawing.Point(16, 112)
    $saveLabel.AutoSize = $true

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.Location = New-Object System.Drawing.Point(16, 134)
    $combo.Size = New-Object System.Drawing.Size(810, 28)
    $combo.Anchor = 'Top,Left,Right'
    $combo.IntegralHeight = $false
    $combo.MaxDropDownItems = 12

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.AutoSize = $false
    $pathLabel.AutoEllipsis = $true
    $pathLabel.Location = New-Object System.Drawing.Point(16, 166)
    $pathLabel.Size = New-Object System.Drawing.Size(810, 22)
    $pathLabel.Anchor = 'Top,Left,Right'
    $pathLabel.ForeColor = [System.Drawing.Color]::DimGray

    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $false
    $hint.Location = New-Object System.Drawing.Point(16, 188)
    $hint.Size = New-Object System.Drawing.Size(810, 36)
    $hint.Anchor = 'Top,Left,Right'

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 230)
    $list.Size = New-Object System.Drawing.Size(810, 280)
    $list.Anchor = 'Top,Bottom,Left,Right'
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    [void]$list.Columns.Add('Time', 230)
    [void]$list.Columns.Add('Size', 90)
    [void]$list.Columns.Add('Backup', 110)
    [void]$list.Columns.Add('Note', 360)

    $restore = New-Object System.Windows.Forms.Button
    $restore.Text = 'Restore selected time'
    $restore.Location = New-Object System.Drawing.Point(16, 524)
    $restore.Size = New-Object System.Drawing.Size(180, 32)
    $restore.Anchor = 'Bottom,Left'

    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'Browse for a folder'
    $browse.Location = New-Object System.Drawing.Point(206, 524)
    $browse.Size = New-Object System.Drawing.Size(160, 32)
    $browse.Anchor = 'Bottom,Left'

    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = 'Refresh'
    $refresh.Location = New-Object System.Drawing.Point(376, 524)
    $refresh.Size = New-Object System.Drawing.Size(100, 32)
    $refresh.Anchor = 'Bottom,Left'

    $status = New-Object System.Windows.Forms.Label
    $status.AutoSize = $false
    $status.Location = New-Object System.Drawing.Point(16, 564)
    $status.Size = New-Object System.Drawing.Size(810, 24)
    $status.Anchor = 'Bottom,Left,Right'
    $status.ForeColor = [System.Drawing.Color]::DimGray

    $form.Controls.AddRange(@($intro, $notes, $saveLabel, $combo, $pathLabel, $hint, $list, $restore, $browse, $refresh, $status))
    $script:ui = @{
        Form    = $form
        Notes   = $notes
        Combo   = $combo
        Path    = $pathLabel
        Hint    = $hint
        List    = $list
        Restore = $restore
        Status  = $status
    }

    $combo.Add_SelectedIndexChanged({ Show-SelectedGroup })
    $list.Add_SelectedIndexChanged({ Update-RestoreButton })
    $list.Add_DoubleClick({ Start-RestoreFromWindow })
    $restore.Add_Click({ Start-RestoreFromWindow })
    $refresh.Add_Click({
            $discovery = Find-SaveGroups -OnlyPath $script:onlyPath -AlsoPath $script:alsoPath
            $preferRoot = $null
            $preferName = $null
            if ($script:ui.Combo.SelectedIndex -ge 0 -and $script:ui.Combo.SelectedIndex -lt $script:groups.Count) {
                $preferRoot = $script:groups[$script:ui.Combo.SelectedIndex].Root
                $preferName = $script:groups[$script:ui.Combo.SelectedIndex].Name
            }
            Import-Discovery -Discovery $discovery -PreferRoot $preferRoot -PreferName $preferName
        })
    $browse.Add_Click({
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Select the folder that contains world0.ksd or a backup folder.'
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $script:onlyPath = $null
            $script:alsoPath = $dialog.SelectedPath
            $discovery = Find-SaveGroups -AlsoPath $script:alsoPath
            Import-Discovery -Discovery $discovery
        })

    Import-Discovery -Discovery $Discovery
    [void]$form.ShowDialog()
}

$script:onlyPath = $null
$script:alsoPath = $null
$script:groups = @()
if ($Path) { $script:onlyPath = $Path }

$discovery = Find-SaveGroups -OnlyPath $script:onlyPath -AlsoPath $script:alsoPath

if ($List) {
    Write-Discovery -Discovery $discovery
    return
}

if ($Choose -gt 0 -or $Slot -gt 0) {
    if ($Choose -lt 1 -or $Slot -lt 1) { throw 'Pass both -Choose and -Slot.' }
    Restore-ChosenSlot -Discovery $discovery -GroupNumber $Choose -SlotNumber $Slot -SkipPrompt ([bool]$Force)
    return
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath)
    if ($Path) { $argList += @('-Path', $Path) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList | Out-Null
    return
}

Show-RestoreWindow -Discovery $discovery
