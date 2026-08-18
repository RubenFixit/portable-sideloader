#Requires -Version 5.1

# Shared helpers: INI parsing, installed-version discovery, version comparison.

function Get-Prop {
    # Safe property read that works under Set-StrictMode for both PSCustomObject and hashtable.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Read-IniFile {
    param([Parameter(Mandatory)][string]$Path)

    $ini = @{}
    $section = ''
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if (-not $ini.ContainsKey($section)) { $ini[$section] = @{} }
            continue
        }
        if ($section -and $t -match '^([^=]+?)\s*=\s*(.*)$') {
            $ini[$section][$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $ini
}

function Get-MainExecutable {
    <#
        Picks the executable the Platform is most likely treating as "the app": an exact name
        match first, then a partial one, then the largest binary. Returns a FileInfo or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$AppDir,
        [string]$Name,
        [string]$Exe
    )

    if ($Exe) {
        $explicit = Join-Path $AppDir $Exe
        if (Test-Path -LiteralPath $explicit) { return Get-Item -LiteralPath $explicit }
    }

    $exes = @(Get-ChildItem -LiteralPath $AppDir -Filter *.exe -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)
    if ($exes.Count -eq 0) { return $null }

    $target = ($Name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    return $exes |
        Sort-Object `
            @{ Expression = {
                $base = ($_.BaseName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
                if ($base -eq $target) { 0 }
                elseif ($target -and ($base -like "*$target*" -or $target -like "*$base*")) { 1 }
                else { 2 }
            } },
            @{ Expression = { $_.Length }; Descending = $true } |
        Select-Object -First 1
}

function Get-InstalledVersion {
    <#
        Three-tier discovery, most authoritative first:
          1. .sideload.json  - written by this tool whenever it installs or updates an app.
          2. App\AppInfo\appinfo.ini - present only once an app is PAF-wrapped.
          3. Main executable's ProductVersion - a heuristic, flagged as such in the report.
    #>
    param(
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$Exe
    )

    $marker = Get-SideloadMarker -AppDir $AppDir
    if ($marker -and (Get-Prop $marker 'version')) {
        return [pscustomobject]@{
            Version   = $marker.version
            Source    = '.sideload.json'
            Heuristic = $false
        }
    }

    $appInfo = Join-Path $AppDir 'App\AppInfo\appinfo.ini'
    if (Test-Path -LiteralPath $appInfo) {
        try {
            $ini = Read-IniFile -Path $appInfo
            if ($ini.ContainsKey('Version')) {
                foreach ($key in 'DisplayVersion', 'PackageVersion') {
                    if ($ini['Version'].ContainsKey($key) -and $ini['Version'][$key]) {
                        return [pscustomobject]@{
                            Version    = $ini['Version'][$key]
                            Source     = 'appinfo.ini'
                            Heuristic  = $false
                        }
                    }
                }
            }
        } catch {
            Write-Verbose "Could not parse $appInfo : $($_.Exception.Message)"
        }
    }

    $candidate = Get-MainExecutable -AppDir $AppDir -Name $Name -Exe $Exe

    if ($candidate) {
        $info = $candidate.VersionInfo
        $version = $info.ProductVersion
        if (-not $version) { $version = $info.FileVersion }
        if ($version) {
            return [pscustomobject]@{
                Version   = $version.Trim()
                Source    = "exe:$($candidate.Name)"
                Heuristic = $true
            }
        }
    }

    return $null
}

function ConvertTo-ComparableVersion {
    # Best-effort normalisation. Returns $null when the string has no usable numeric core,
    # which pushes the caller onto a plain string comparison instead of guessing.
    param([string]$Raw)

    if (-not $Raw) { return $null }
    $s = ($Raw.Trim() -replace '^[vV]', '')
    # Win32 FileVersion resources often read "4, 7, 2, 0", so commas count as separators too.
    $m = [regex]::Match($s, '\d+(?:\s*[._,-]\s*\d+){0,3}')
    if (-not $m.Success) { return $null }

    $parts = @($m.Value -split '\s*[._,-]\s*' | Select-Object -First 4)
    while ($parts.Count -lt 4) { $parts += '0' }

    try {
        return [version]::new([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
    } catch {
        return $null
    }
}

function Compare-AppVersion {
    <#
        UpToDate        - installed >= latest
        UpdateAvailable - latest > installed
        Differs         - both known but not numerically comparable; eyeball it
        NoBaseline      - installed version could not be determined
        Unknown         - upstream version could not be determined
    #>
    param([string]$Installed, [string]$Latest)

    if (-not $Latest)    { return 'Unknown' }
    if (-not $Installed) { return 'NoBaseline' }

    $a = ConvertTo-ComparableVersion $Installed
    $b = ConvertTo-ComparableVersion $Latest

    if ($a -and $b) {
        if ($b -gt $a) { return 'UpdateAvailable' }
        return 'UpToDate'
    }

    if ($Installed.Trim() -eq $Latest.Trim()) { return 'UpToDate' }
    return 'Differs'
}

function Resolve-PortableAppsRoot {
    param([string]$Explicit, [string]$FromManifest)

    foreach ($candidate in @($Explicit, $FromManifest)) {
        if ($candidate) {
            if (-not (Test-Path -LiteralPath $candidate)) {
                throw "PortableApps root not found: $candidate"
            }
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $guesses = @(
        (Join-Path $env:USERPROFILE 'PortableApps\PortableApps'),
        'C:\PortableApps\PortableApps',
        'D:\PortableApps\PortableApps',
        'E:\PortableApps\PortableApps'
    )
    foreach ($g in $guesses) {
        if (Test-Path -LiteralPath $g) { return (Resolve-Path -LiteralPath $g).Path }
    }

    throw "Could not locate a PortableApps directory. Pass -PortableAppsRoot or set portableAppsRoot in apps.json."
}
