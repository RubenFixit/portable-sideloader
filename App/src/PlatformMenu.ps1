#Requires -Version 5.1

<#
    Reads and writes the Platform's own menu config, PortableApps.com\Data\PortableAppsMenu.ini.

    Non-PAF apps appear under "Other" until you recategorise them, and the Platform stores that
    choice here rather than in the app folder:

        [AppsRecategorized]
        orcaslicer\orca-slicer.exe=Development

    Two consequences worth knowing:

      * Categories survive our folder swaps, because they live outside the app folder.
      * The key includes the executable name, so an update that RENAMES the exe silently drops
        the category (and any rename or hidden flag) back to default.

    The file is UTF-16LE with a BOM, and the Platform holds it in memory and rewrites it on exit,
    so it must not be written while the Platform is running.
#>

$script:MenuSections = @{
    Category = 'AppsRecategorized'
    Rename   = 'AppsRenamed'
    Hidden   = 'AppsHidden'
}

function Test-PlatformRunning {
    return [bool](Get-Process -Name 'PortableAppsPlatform', 'PortableApps.comPlatform', 'Start' -ErrorAction SilentlyContinue)
}

function Resolve-MenuIniPath {
    param([Parameter(Mandatory)][string]$Root, [string]$Override)
    if ($Override) { return $Override }
    return (Join-Path $Root 'PortableApps.com\Data\PortableAppsMenu.ini')
}

function Get-MenuIniText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Platform menu config not found: $Path" }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::Unicode)
}

function Get-MenuEntries {
    <#
        Returns a hashtable of "folder\exe.exe" -> value for one section.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Section)

    $result = @{}
    $inSection = $false
    foreach ($line in (Get-MenuIniText -Path $Path) -split "`r`n") {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $inSection = ($Matches[1] -eq $Section); continue }
        if (-not $inSection -or $t -eq '' -or $t.StartsWith(';')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -gt 0) { $result[$t.Substring(0, $eq).Trim()] = $t.Substring($eq + 1).Trim() }
    }
    return $result
}

function Set-MenuEntries {
    <#
        Merges keys into one section, leaving every other byte of the file alone. Writes back as
        UTF-16LE with BOM and CRLF line endings, matching what the Platform produces.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][hashtable]$Entries,
        [switch]$WhatIf
    )

    $lines = [Collections.Generic.List[string]](@((Get-MenuIniText -Path $Path) -split "`r`n"))

    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "[$Section]") { $start = $i; break }
    }
    if ($start -lt 0) {
        $lines.Add("[$Section]")
        $start = $lines.Count - 1
    }

    $end = $lines.Count
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j].Trim() -match '^\[.+\]$') { $end = $j; break }
    }

    $changes = @()

    foreach ($key in $Entries.Keys) {
        $wanted = "$key=$($Entries[$key])"
        $found = -1
        for ($k = $start + 1; $k -lt $end; $k++) {
            $t = $lines[$k].Trim()
            $eq = $t.IndexOf('=')
            if ($eq -gt 0 -and $t.Substring(0, $eq).Trim() -eq $key) { $found = $k; break }
        }
        if ($found -ge 0) {
            if ($lines[$found].Trim() -ne $wanted) {
                $changes += [pscustomobject]@{ Key = $key; From = $lines[$found].Trim(); To = $wanted }
                if (-not $WhatIf) { $lines[$found] = $wanted }
            }
        } else {
            $changes += [pscustomobject]@{ Key = $key; From = $null; To = $wanted }
            if (-not $WhatIf) { $lines.Insert($end, $wanted); $end++ }
        }
    }

    if (-not $WhatIf -and $changes.Count -gt 0) {
        Copy-Item -LiteralPath $Path -Destination "$Path.sideload-backup" -Force
        $utf16 = New-Object System.Text.UnicodeEncoding($false, $true)
        [IO.File]::WriteAllText($Path, ($lines -join "`r`n"), $utf16)
    }

    # Unary comma: the caller reads .Count directly, so a single change must stay an array.
    return , ([object[]]$changes)
}

function Get-MenuKey {
    <#
        The Platform keys these sections by lowercase "appfolder\executable.exe", relative to the
        PortableApps directory.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Id, $Executable)
    if (-not $Executable) { return $null }
    $rel = $Executable.FullName.Substring((Join-Path $Root $Id).Length).TrimStart('\')
    return "$Id\$rel".ToLowerInvariant()
}

function Get-AppMenuKeys {
    <#
        Every menu key an app could plausibly own, best guess first.

        The Platform lists each executable it finds, and which one you categorised is your choice,
        not something we can derive. VSCodium is the awkward case: the folder holds a 4 MB
        launcher stub and a 191 MB binary, and the Platform entry points at the stub while version
        detection wants the binary. So rather than pick one, return them all - ordered with the
        one matching the folder name first, since that is what the Platform tends to surface.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Id,
        [string]$Name
    )

    # No unary comma on these returns: every caller already wraps the result in @(), and doing
    # both produces an array containing an array.
    $appDir = Join-Path $Root $Id
    if (-not (Test-Path -LiteralPath $appDir)) { return @() }

    $target = ($Id -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    $exes = @(Get-ChildItem -LiteralPath $appDir -Filter *.exe -File -Recurse -Depth 3 -ErrorAction SilentlyContinue) |
        Sort-Object `
            @{ Expression = {
                $base = ($_.BaseName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
                if ($base -eq $target) { 0 } elseif ($base -like "*$target*" -or $target -like "*$base*") { 1 } else { 2 }
            } },
            @{ Expression = { $_.FullName.Split('\').Count } },
            @{ Expression = { $_.Length }; Descending = $true }

    return @($exes | ForEach-Object { Get-MenuKey -Root $Root -Id $Id -Executable $_ })
}
