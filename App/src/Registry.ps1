#Requires -Version 5.1

# apps.json read/write, plus the cached bucket index that powers `search` and `install`.
# Which buckets exist, and where their manifests live, comes from config.json.

function Get-AppManifest {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ portableAppsRoot = $null; apps = @() }
    }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Save-AppManifest {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Path)
    # Sort by id so hand edits and tool edits produce reviewable diffs.
    $Manifest.apps = @($Manifest.apps | Sort-Object { $_.id })
    $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ManagedApp {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Id)
    return @($Manifest.apps | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
}

function Add-ManagedApp {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)]$Entry)
    if (Get-ManagedApp -Manifest $Manifest -Id $Entry.id) {
        throw "'$($Entry.id)' is already managed. Use 'update' to change its version, or 'remove' first."
    }
    $Manifest.apps = @($Manifest.apps) + $Entry
    return $Manifest
}

function Remove-ManagedApp {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Id)
    $Manifest.apps = @($Manifest.apps | Where-Object { $_.id -ne $Id })
    return $Manifest
}

function Get-BucketIndex {
    <#
        Lists every manifest name in the official Scoop buckets. Cached locally because it is
        three git-tree calls and the answer changes slowly.
    #>
    param(
        [Parameter(Mandatory)][string]$CachePath,
        [Parameter(Mandatory)]$Config,
        [int]$MaxAgeHours = 24,
        [switch]$Force,
        [int]$TimeoutSec = 30
    )

    if (-not $Force -and (Test-Path -LiteralPath $CachePath)) {
        try {
            $cached = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
            $age = (New-TimeSpan -Start ([datetime]$cached.fetchedUtc) -End (Get-Date).ToUniversalTime()).TotalHours
            if ($age -lt $MaxAgeHours) { return , @($cached.entries) }
        } catch {
            Write-Verbose "Bucket cache unreadable, refetching: $($_.Exception.Message)"
        }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($bucket in @(Get-Prop $Config 'buckets')) {
        $repo = Get-Prop $bucket 'indexRepo'
        if (-not $repo) {
            Write-Verbose "Bucket '$($bucket.name)' has no indexRepo; it can still be used by exact name."
            continue
        }
        $uri = "https://api.github.com/repos/$repo/git/trees/master?recursive=1"
        try {
            $tree = Invoke-RestMethod -Uri $uri -Headers (Get-RequestHeaders -GitHubApi) -TimeoutSec $TimeoutSec
            foreach ($node in $tree.tree) {
                if ($node.path -like 'bucket/*.json') {
                    $entries.Add([pscustomobject]@{
                        Name   = [IO.Path]::GetFileNameWithoutExtension($node.path)
                        Bucket = $bucket.name
                        Rank   = [int](Get-Prop $bucket 'rank' 99)
                    })
                }
            }
        } catch {
            Write-Warning "Could not index bucket '$($bucket.name)': $($_.Exception.Message)"
        }
    }

    if ($entries.Count -eq 0) { throw 'Bucket index came back empty; check network access to github.com.' }


    $dir = Split-Path -Parent $CachePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [pscustomobject]@{
        fetchedUtc = (Get-Date).ToUniversalTime().ToString('o')
        entries    = $entries
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $CachePath -Encoding UTF8

    return , @($entries)
}

function Find-BucketManifest {
    param(
        [Parameter(Mandatory)]$Index,
        [Parameter(Mandatory)][string]$Term,
        [string]$Bucket
    )
    $hits = @($Index | Where-Object { $_.Name -like "*$Term*" })
    if ($Bucket) { $hits = @($hits | Where-Object { $_.Bucket -eq $Bucket }) }

    # Exact name wins over substring, then bucket rank from config.json, then shortest name.
    # Unary comma so a single match still comes back as an array, not a bare object.
    return , @($hits | Sort-Object `
        @{ Expression = { if ($_.Name -eq $Term) { 0 } else { 1 } } },
        @{ Expression = { [int](Get-Prop $_ 'Rank' 99) } },
        @{ Expression = { $_.Name.Length } })
}
