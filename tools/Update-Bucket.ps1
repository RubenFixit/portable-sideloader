#Requires -Version 5.1
<#
.SYNOPSIS
    Check or update manifests in the personal Scoop-compatible bucket.

.DESCRIPTION
    Reuses portable-sideloader's existing GitHub and URL providers. Manifests opt in with an
    x-portable-sideloader object containing provider and source fields. Without -Apply this is a
    report only; -Apply writes version, url and hash changes back to the manifest JSON.

.EXAMPLE
    .\tools\Update-Bucket.ps1

.EXAMPLE
    .\tools\Update-Bucket.ps1 -Manifest libation-chardonnay -Apply
#>
[CmdletBinding()]
param(
    [string] $PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $BucketPath  = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bucket'),
    [string] $Manifest,
    [switch] $Apply,
    [int]    $TimeoutSec = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PackageRoot 'App\src\Common.ps1')
. (Join-Path $PackageRoot 'App\src\Providers.ps1')

$config = Get-Content -LiteralPath (Join-Path $PackageRoot 'App\config.json') -Raw | ConvertFrom-Json
Set-ProviderConfig -Config $config

if (-not (Test-Path -LiteralPath $BucketPath)) { throw "Bucket path not found: $BucketPath" }
$files = @(Get-ChildItem -LiteralPath $BucketPath -Filter '*.json' -File |
    Where-Object { -not $Manifest -or $_.BaseName -eq $Manifest } | Sort-Object Name)
if ($files.Count -eq 0) { throw "No bucket manifests found$(if ($Manifest) { " matching '$Manifest'" })." }

function Get-ArtifactSha256 {
    param([Parameter(Mandatory)][string]$Url)

    $target = Join-Path ([IO.Path]::GetTempPath()) ("sideload-bucket-" + [guid]::NewGuid().ToString('N') + '.download')
    try {
        Invoke-WebRequest -Uri $Url -OutFile $target -UseBasicParsing -Headers (Get-RequestHeaders) -TimeoutSec $TimeoutSec
        return (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    finally {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    }
}

$changed = 0
$skipped = 0
$failed = 0

foreach ($file in $files) {
    try {
        $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        $meta = Get-Prop $json 'x-portable-sideloader'
        if (-not $meta) {
            Write-Host ("  {0,-34} skipped (no x-portable-sideloader source)" -f $file.BaseName) -ForegroundColor DarkGray
            $skipped++
            continue
        }

        $provider = [string](Get-Prop $meta 'provider')
        $source = Get-Prop $meta 'source'
        if (-not $provider -or -not $source) { throw 'metadata needs provider and source' }

        $latest = Get-LatestVersion -Provider $provider -Source $source -TimeoutSec $TimeoutSec
        $current = [string](Get-Prop $json 'version')
        $sameVersion = $current -eq [string]$latest.Version
        $hash = if ($latest.Hash) { [string]$latest.Hash } else { [string](Get-Prop $json 'hash') }
        $hashNote = if ($latest.Hash) { 'hash from provider' } elseif ($latest.Url) { 'existing hash retained' } else { 'no hash' }

        if (-not $latest.Hash -and $latest.Url -and (-not $sameVersion -or -not $hash)) {
            $hash = Get-ArtifactSha256 -Url ([string]$latest.Url)
            $hashNote = 'hash downloaded and verified'
        }

        if ($sameVersion -and [string](Get-Prop $json 'url') -eq [string]$latest.Url) {
            Write-Host ("  {0,-34} {1} (up to date; {2})" -f $file.BaseName, $current, $hashNote) -ForegroundColor Green
            continue
        }

        Write-Host ("  {0,-34} {1} -> {2} ({3})" -f $file.BaseName, $current, $latest.Version, $hashNote) -ForegroundColor Yellow
        if (-not $Apply) { $changed++; continue }

        $json.version = [string]$latest.Version
        if ($latest.Url) { $json.url = [string]$latest.Url }
        if ($hash) { $json.hash = $hash }
        $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file.FullName -Encoding UTF8
        $changed++
    }
    catch {
        Write-Host ("  {0,-34} ERROR: {1}" -f $file.BaseName, $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}

Write-Host ''
if ($Apply) {
    Write-Host ("  updated {0} manifest(s); skipped {1}; failed {2}" -f $changed, $skipped, $failed) -ForegroundColor Cyan
} else {
    Write-Host ("  {0} manifest(s) would change; skipped {1}; failed {2}" -f $changed, $skipped, $failed) -ForegroundColor Cyan
    Write-Host '  preview only - pass -Apply to write manifest changes' -ForegroundColor DarkGray
}
if ($failed -gt 0) { exit 1 }
