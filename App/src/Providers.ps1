#Requires -Version 5.1

# Upstream version providers. Each returns:
#   @{ Version; Url; Hash; Persist; Origin }
# or throws with a message that lands in the report's Detail column.
#
# Provider behaviour is driven by config.json - bucket URLs, the user agent and the version
# pattern library all come from there rather than being baked in here.

$script:Config    = $null
$script:UserAgent = 'portable-sideloader'

function Set-ProviderConfig {
    param($Config)
    $script:Config = $Config
    $ua = Get-Prop (Get-Prop $Config 'settings') 'userAgent'
    if ($ua) { $script:UserAgent = $ua }
}

function Get-RequestHeaders {
    param([switch]$GitHubApi)
    $h = @{ 'User-Agent' = $script:UserAgent }
    if ($GitHubApi) {
        $h['Accept'] = 'application/vnd.github+json'
        if ($env:GITHUB_TOKEN) { $h['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    }
    return $h
}

function Get-BucketDefinition {
    param([Parameter(Mandatory)][string]$Name)
    $bucket = @(Get-Prop $script:Config 'buckets') | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $bucket) {
        throw "Bucket '$Name' is not defined in config.json. Add it under 'buckets' to use it."
    }
    return $bucket
}

function Get-LatestFromScoop {
    <#
        Reads a bucket manifest straight off its raw URL. Scoop itself is not installed or
        required - this borrows the community's checkver/autoupdate maintenance while keeping
        this tool self-contained. Custom buckets work by adding them to config.json.
    #>
    param([Parameter(Mandatory)]$Source, [int]$TimeoutSec = 30)

    $bucketName = Get-Prop $Source 'bucket'
    $manifest   = Get-Prop $Source 'manifest'
    if (-not $bucketName -or -not $manifest) { throw "scoop source needs 'bucket' and 'manifest'" }

    $bucket = Get-BucketDefinition -Name $bucketName
    $uri    = ([string]$bucket.manifestUrl).Replace('{name}', $manifest)
    $m      = Invoke-RestMethod -Uri $uri -Headers (Get-RequestHeaders) -TimeoutSec $TimeoutSec

    $url  = Get-Prop $m 'url'
    $hash = Get-Prop $m 'hash'

    if (-not $url) {
        $arch = Get-Prop $m 'architecture'
        $spec = $null
        foreach ($a in '64bit', 'arm64', '32bit') {
            $spec = Get-Prop $arch $a
            if ($spec) { break }
        }
        if ($spec) {
            $url  = Get-Prop $spec 'url'
            $hash = Get-Prop $spec 'hash'
        }
    }

    # 'persist' names the folders Scoop keeps across upgrades - i.e. the app's user data.
    # Reusing it means we preserve the right paths without hand-maintaining that list.
    $persist = @()
    foreach ($p in @(Get-Prop $m 'persist')) {
        if ($p -is [string]) { $persist += $p }
        elseif ($p) { $persist += @($p)[0] }   # ["source","target"] form
    }

    return [pscustomobject]@{
        Version = Get-Prop $m 'version'
        Url     = @($url)  | Select-Object -First 1
        Hash    = @($hash) | Select-Object -First 1
        Persist = $persist
        Origin  = "scoop:$bucketName/$manifest"
    }
}

function Get-LatestFromGitHub {
    param([Parameter(Mandatory)]$Source, [int]$TimeoutSec = 30)

    $repo = Get-Prop $Source 'repo'
    if (-not $repo) { throw "github source needs 'repo'" }

    $includePre = [bool](Get-Prop $Source 'prerelease' $false)
    $rel = if ($includePre) {
        @(Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=10" `
            -Headers (Get-RequestHeaders -GitHubApi) -TimeoutSec $TimeoutSec) | Select-Object -First 1
    } else {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
            -Headers (Get-RequestHeaders -GitHubApi) -TimeoutSec $TimeoutSec
    }

    $asset = $null
    $pattern = Get-Prop $Source 'assetPattern'
    if ($pattern) {
        $asset = @(Get-Prop $rel 'assets') | Where-Object { $_ -and $_.name -match $pattern } | Select-Object -First 1
        if (-not $asset) { Write-Verbose "No asset matched /$pattern/ in $repo $(Get-Prop $rel 'tag_name')" }
    }

    $hash = if ($asset) { Get-Prop $asset 'digest' } else { $null }
    if ($hash -and $hash -match '^sha256:') { $hash = $hash.Substring(7) }

    return [pscustomobject]@{
        Version = ((Get-Prop $rel 'tag_name' '') -replace '^[vV]', '')
        Url     = if ($asset) { $asset.browser_download_url } else { $null }
        Hash    = $hash
        Persist = @()
        Origin  = "github:$repo"
    }
}

function Get-LatestFromUrl {
    <#
        Scrapes a watch page for every string matching versionPattern and takes the highest
        version found, rather than the first one on the page. Ordering beats document order:
        vendor pages routinely list the newest release below a banner or changelog entry.

        versionPattern is normally derived from the original download URL (see Infer.ps1), so it
        matches only links shaped like that file. A bare version regex would match anything.
    #>
    param([Parameter(Mandatory)]$Source, [int]$TimeoutSec = 30)

    $watch    = Get-Prop $Source 'watchUrl'
    if (-not $watch) { $watch = Get-Prop $Source 'url' }   # legacy 'html' provider spelling
    $pattern  = Get-Prop $Source 'versionPattern'
    $template = Get-Prop $Source 'urlTemplate'
    if (-not $watch)   { throw "url source needs 'watchUrl'" }
    if (-not $pattern) { throw "url source needs 'versionPattern'" }

    $html = (Invoke-WebRequest -Uri $watch -UseBasicParsing -Headers (Get-RequestHeaders) -TimeoutSec $TimeoutSec).Content
    $hits = [regex]::Matches($html, $pattern)
    if ($hits.Count -eq 0) { throw "versionPattern matched nothing at $watch" }

    $best = $null
    $bestComparable = $null
    foreach ($hit in $hits) {
        $raw = if ($hit.Groups['version'].Success) { $hit.Groups['version'].Value }
               elseif ($hit.Groups.Count -gt 1)    { $hit.Groups[1].Value }
               else                                { $hit.Value }
        $comparable = ConvertTo-ComparableVersion $raw
        if ($null -eq $best) { $best = $raw; $bestComparable = $comparable; continue }
        if ($comparable -and $bestComparable -and $comparable -gt $bestComparable) {
            $best = $raw; $bestComparable = $comparable
        }
    }

    $url = if ($template) { ([string]$template).Replace('{version}', $best) } else { Get-Prop $Source 'downloadUrl' }

    return [pscustomobject]@{
        Version = $best
        Url     = $url
        Hash    = $null
        Persist = @()
        Origin  = "url:$watch"
    }
}

function Get-LatestVersion {
    param(
        [Parameter(Mandatory)][string]$Provider,
        $Source,
        [int]$TimeoutSec = 30
    )

    switch ($Provider) {
        'scoop'  { return Get-LatestFromScoop  -Source $Source -TimeoutSec $TimeoutSec }
        'github' { return Get-LatestFromGitHub -Source $Source -TimeoutSec $TimeoutSec }
        'url'    { return Get-LatestFromUrl    -Source $Source -TimeoutSec $TimeoutSec }
        'html'   { return Get-LatestFromUrl    -Source $Source -TimeoutSec $TimeoutSec }  # legacy alias
        'todo'   { throw 'No detection rule written yet' }
        default  { throw "Unknown provider '$Provider'" }
    }
}
