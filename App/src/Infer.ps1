#Requires -Version 5.1

# Turns a plain download URL into a complete apps.json entry, using only the rules in config.json.
# Nothing here knows about a specific vendor; add hosts and version shapes to the config instead.

function Merge-Config {
    <#
        Layers a local override file over the shipped defaults.

        Scalars replace. Nested objects merge key by key. Arrays put the local entries FIRST and
        drop shipped entries with the same `name` (or the same value, for plain strings) - so a
        local host rule or version pattern wins, a local bucket replaces the shipped one of the
        same name, and everything you did not mention survives an update untouched.
    #>
    param($Base, $Override)

    if (-not $Override) { return $Base }

    foreach ($prop in $Override.PSObject.Properties) {
        $name = $prop.Name
        $ov   = $prop.Value
        $bv   = Get-Prop $Base $name

        if ($ov -is [array] -and $bv -is [array]) {
            $merged = @()
            $seen   = @{}
            foreach ($item in (@($ov) + @($bv))) {
                $key = if ($item -is [string]) { $item } else { [string](Get-Prop $item 'name') }
                if ($key) {
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                }
                $merged += $item
            }
            $Base | Add-Member -NotePropertyName $name -NotePropertyValue $merged -Force
        }
        elseif ($ov -is [System.Management.Automation.PSCustomObject] -and
                $bv -is [System.Management.Automation.PSCustomObject]) {
            $Base | Add-Member -NotePropertyName $name -NotePropertyValue (Merge-Config -Base $bv -Override $ov) -Force
        }
        else {
            $Base | Add-Member -NotePropertyName $name -NotePropertyValue $ov -Force
        }
    }
    return $Base
}

function Get-Config {
    <#
        App\config.json holds the shipped defaults and is replaced wholesale on update.
        Data\config.local.json holds your overrides and is never touched.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$LocalPath)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config not found: $Path"
    }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    if ($LocalPath -and (Test-Path -LiteralPath $LocalPath)) {
        try {
            $local = Get-Content -LiteralPath $LocalPath -Raw | ConvertFrom-Json
        } catch {
            throw "Could not parse $LocalPath : $($_.Exception.Message)"
        }
        $config = Merge-Config -Base $config -Override $local
        Write-Verbose "Layered overrides from $LocalPath"
    }
    return $config
}

function Get-Setting {
    # Precedence: explicit command-line value, then config.json, then the built-in fallback.
    param($Config, [string]$Name, $Override = $null, $Fallback = $null)
    if ($null -ne $Override -and $Override -ne '' -and $Override -ne 0) { return $Override }
    $settings = Get-Prop $Config 'settings'
    $value = Get-Prop $settings $Name
    if ($null -ne $value -and $value -ne '') { return $value }
    return $Fallback
}

function New-VersionRegex {
    <#
        Finds the version inside a string and rebuilds that string as a regex, with everything
        except the version escaped. The result matches other releases of the same file and
        nothing else - far tighter than hunting for a bare \d+\.\d+\.\d+ across a whole page.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$Patterns,
        [switch]$Capture,
        [switch]$Anchor
    )

    foreach ($p in $Patterns) {
        $m = [regex]::Match($Text, $p.regex)
        if (-not $m.Success) { continue }

        $before = [regex]::Escape($Text.Substring(0, $m.Index))
        $after  = [regex]::Escape($Text.Substring($m.Index + $m.Length))
        $core   = if ($Capture) { "(?<version>$($p.regex))" } else { $p.regex }
        $regex  = "$before$core$after"
        if ($Anchor) { $regex = "^$regex$" }

        return [pscustomobject]@{
            Regex   = $regex
            Version = $m.Value
            Pattern = $p.name
        }
    }
    return $null
}

function Expand-SourceToken {
    param([string]$Template, [hashtable]$Tokens)
    $out = $Template
    foreach ($key in $Tokens.Keys) {
        $out = $out.Replace('${' + $key + '}', [string]$Tokens[$key])
    }
    return $out
}

function Resolve-SourceFromUrl {
    <#
        Returns an object describing what was inferred, including the version it found and which
        rule fired, so `explain` can show its work before anything is written to disk.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)]$Config,
        [string]$WatchUrl
    )

    $patterns = @(Get-Prop $Config 'versionPatterns')
    if ($patterns.Count -eq 0) { throw 'config.json defines no versionPatterns.' }

    $uri      = [uri](Get-DownloadUri $Url)
    $fileName = Get-DownloadFileName $Url

    $assetInfo = New-VersionRegex -Text $fileName -Patterns $patterns -Anchor
    $scrapeInfo = New-VersionRegex -Text $fileName -Patterns $patterns -Capture

    # Default watch page is the directory the file sits in; most vendors keep an index there.
    $parent = $Url
    if (-not $WatchUrl) {
        $path = $uri.AbsolutePath
        $dir  = $path.Substring(0, [Math]::Max($path.LastIndexOf('/'), 0))
        $parent = "$($uri.Scheme)://$($uri.Authority)$dir/"
    }

    $urlTemplate = $Url
    if ($assetInfo) {
        # Replace every occurrence - the version often appears in both the tag and the filename.
        $urlTemplate = $Url.Replace($assetInfo.Version, '{version}')
    }

    $tokens = @{
        watchUrl      = if ($WatchUrl) { $WatchUrl } else { $parent }
        urlTemplate   = $urlTemplate
        assetRegex    = if ($assetInfo)  { $assetInfo.Regex }  else { '' }
        filenameRegex = if ($scrapeInfo) { $scrapeInfo.Regex } else { '' }
    }

    foreach ($rule in @(Get-Prop $Config 'hosts')) {
        $m = [regex]::Match($Url, $rule.match)
        if (-not $m.Success) { continue }

        foreach ($g in $m.Groups) {
            if ($g.Name -notmatch '^\d+$' -and $g.Success) { $tokens[$g.Name] = $g.Value }
        }

        $source = [ordered]@{}
        foreach ($prop in (Get-Prop $rule 'source').PSObject.Properties) {
            $value = Expand-SourceToken -Template ([string]$prop.Value) -Tokens $tokens
            if ($value -ne '') { $source[$prop.Name] = $value }
        }

        return [pscustomobject]@{
            Rule            = $rule.name
            Provider        = $rule.provider
            Source          = [pscustomobject]$source
            DetectedVersion = if ($assetInfo) { $assetInfo.Version } else { $null }
            VersionPattern  = if ($assetInfo) { $assetInfo.Pattern } else { $null }
            FileName        = $fileName
            Warnings        = @(
                if (-not $assetInfo) {
                    "No version found in '$fileName'. Updates cannot be tracked from this URL alone - pass -WatchUrl and -VersionPattern, or edit the entry in apps.json."
                }
            ) | Where-Object { $_ }
        }
    }

    throw "No host rule in config.json matched '$Url'."
}

function New-AppEntryFromUrl {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Config,
        [string]$DisplayName,
        [string]$WatchUrl,
        [string]$VersionPattern,
        [string[]]$Preserve
    )

    $inferred = Resolve-SourceFromUrl -Url $Url -Config $Config -WatchUrl $WatchUrl

    if ($VersionPattern) {
        $inferred.Source | Add-Member -NotePropertyName 'versionPattern' -NotePropertyValue $VersionPattern -Force
        $inferred.Warnings = @()
    }

    $entry = [pscustomobject]@{
        id       = $Id
        name     = if ($DisplayName) { $DisplayName } else { $Id }
        provider = $inferred.Provider
        source   = $inferred.Source
    }
    if ($Preserve) { $entry | Add-Member -NotePropertyName 'preserve' -NotePropertyValue $Preserve }

    return [pscustomobject]@{ Entry = $entry; Inferred = $inferred }
}
