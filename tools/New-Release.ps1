#Requires -Version 5.1
<#
.SYNOPSIS
    Stage and zip a release artifact.

.DESCRIPTION
    Builds the icon and launcher, then assembles exactly what ships: the stub, App\, tools\, the
    Data\ examples, and the docs. Deliberately excludes Data\apps.json, Data\state.json and the
    caches - those are yours, and a release must never carry someone else's registry.

    Scripted rather than done by hand so nothing gets forgotten, and so the zip is reproducible.

.EXAMPLE
    .\tools\New-Release.ps1

.EXAMPLE
    .\tools\New-Release.ps1 -OutputDir C:\Temp\release
#>
[CmdletBinding()]
param(
    [string] $PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $OutputDir   = (Join-Path ([IO.Path]::GetTempPath()) 'portable-sideloader-release'),
    [string] $Name        = 'PortableSideloader'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = (Get-Content -LiteralPath (Join-Path $PackageRoot 'App\VERSION') -Raw).Trim()
$staging = Join-Path $OutputDir $Name

if (Test-Path -LiteralPath $OutputDir) { Remove-Item -LiteralPath $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $staging 'Data') -Force | Out-Null

& (Join-Path $PSScriptRoot 'New-Icon.ps1') | Out-Null
& (Join-Path $PSScriptRoot 'build.ps1') -PackageRoot $PackageRoot | Out-Null

Copy-Item -LiteralPath (Join-Path $PackageRoot "$Name.exe") -Destination $staging
Copy-Item -LiteralPath (Join-Path $PackageRoot 'App')   -Destination $staging -Recurse
Copy-Item -LiteralPath (Join-Path $PackageRoot 'tools') -Destination $staging -Recurse
foreach ($doc in 'README.md', 'LICENSE') {
    Copy-Item -LiteralPath (Join-Path $PackageRoot $doc) -Destination $staging
}
foreach ($sample in 'apps.example.json', 'config.local.example.json') {
    Copy-Item -LiteralPath (Join-Path $PackageRoot "Data\$sample") -Destination (Join-Path $staging 'Data')
}

$leaked = @(Get-ChildItem -LiteralPath (Join-Path $staging 'Data') -File |
    Where-Object { $_.Name -in 'apps.json', 'state.json', 'config.local.json' })
if ($leaked.Count -gt 0) { throw "Refusing to package personal files: $(($leaked.Name) -join ', ')" }

$zip = Join-Path $OutputDir "$Name-$version.zip"
Compress-Archive -Path $staging -DestinationPath $zip -CompressionLevel Optimal

$info = Get-Item -LiteralPath $zip
$stagingFull = (Resolve-Path -LiteralPath $staging).Path
Write-Host ''
Write-Host ("  {0}  ({1:N0} KB)" -f $info.Name, ($info.Length / 1KB)) -ForegroundColor Green
Write-Host "  $zip" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  contents:' -ForegroundColor DarkGray
Get-ChildItem -LiteralPath $staging -Recurse -File |
    ForEach-Object { '    ' + $_.FullName.Substring($stagingFull.Length + 1) }
Write-Host ''
Write-Host "  gh release create v$version `"$zip`" --repo RubenFixit/portable-sideloader --title v$version --notes ..." -ForegroundColor DarkGray
Write-Host ''
