#Requires -Version 5.1
<#
.SYNOPSIS
    Compile the launcher stub.

.DESCRIPTION
    Uses the C# compiler that ships with the .NET Framework on every Windows install, so building
    needs no SDK, no package manager, and no admin rights.

    Version-resource fields are generated from App\VERSION so the compiled exe always agrees with
    what `update` reports. Without them csc emits an empty version resource, and the PortableApps
    menu shows the app with no name at all.

    Output lands at the package root, next to App\ and Data\, which is where the Platform expects
    an app's executable to be.

.EXAMPLE
    .\tools\build.ps1

.EXAMPLE
    .\tools\build.ps1 -NoIcon
#>
[CmdletBinding()]
param(
    [string] $Name        = 'PortableSideloader',
    [string] $PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $OutputDir,
    [string] $SourcePath,
    [string] $IconPath,
    [switch] $NoIcon
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputDir)  { $OutputDir  = $PackageRoot }
if (-not $SourcePath) { $SourcePath = Join-Path $PackageRoot 'App\Launcher\Launcher.cs' }
if (-not $IconPath -and -not $NoIcon) {
    $IconPath = Join-Path $PackageRoot 'App\Launcher\PortableSideloader.ico'
}

function Find-CSharpCompiler {
    $roots = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $found = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^v\d' } |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'csc.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($found) { return $found }
    }
    throw 'Could not find csc.exe. The .NET Framework 4.x compiler ships with Windows; check %WINDIR%\Microsoft.NET.'
}

function Get-PackageVersion {
    param([string]$Root)
    $file = Join-Path $Root 'App\VERSION'
    $raw = if (Test-Path -LiteralPath $file) { (Get-Content -LiteralPath $file -Raw).Trim() } else { '0.0.0' }
    # Assembly versions must be four numeric parts.
    $parts = @(($raw -split '[^\d]+') | Where-Object { $_ -ne '' } | Select-Object -First 4)
    while ($parts.Count -lt 4) { $parts += '0' }
    return [pscustomobject]@{ Display = $raw; Assembly = ($parts -join '.') }
}

if (-not (Test-Path -LiteralPath $SourcePath)) { throw "Source not found: $SourcePath" }

$csc = Find-CSharpCompiler
$version = Get-PackageVersion -Root $PackageRoot
$out = Join-Path $OutputDir "$Name.exe"

Write-Host ''
Write-Host "  compiler  $csc" -ForegroundColor DarkGray
Write-Host "  source    $SourcePath" -ForegroundColor DarkGray
Write-Host "  version   $($version.Display)  (assembly $($version.Assembly))" -ForegroundColor DarkGray
Write-Host "  icon      $(if ($IconPath) { $IconPath } else { '(none)' })" -ForegroundColor DarkGray
Write-Host "  output    $out" -ForegroundColor DarkGray
Write-Host ''

# csc turns these attributes into the Win32 version resource. AssemblyTitle becomes
# FileDescription, which is the string the PortableApps menu displays.
$assemblyInfo = Join-Path ([IO.Path]::GetTempPath()) ("sideload-assemblyinfo-" + [guid]::NewGuid().ToString('N') + '.cs')
@"
using System.Reflection;

[assembly: AssemblyTitle("Portable Sideloader")]
[assembly: AssemblyDescription("Updates manually added PortableApps.com apps")]
[assembly: AssemblyProduct("portable-sideloader")]
[assembly: AssemblyCompany("RubenFixit")]
[assembly: AssemblyCopyright("MIT licensed")]
[assembly: AssemblyVersion("$($version.Assembly)")]
[assembly: AssemblyFileVersion("$($version.Assembly)")]
[assembly: AssemblyInformationalVersion("$($version.Display)")]
"@ | Set-Content -LiteralPath $assemblyInfo -Encoding UTF8

try {
    $cscArgs = @('/nologo', '/target:exe', '/platform:anycpu', '/optimize+', "/out:$out")
    if ($IconPath) {
        if (-not (Test-Path -LiteralPath $IconPath)) {
            throw "Icon not found: $IconPath. Run tools\New-Icon.ps1, or pass -NoIcon."
        }
        $cscArgs += "/win32icon:$IconPath"
    }
    $cscArgs += @($SourcePath, $assemblyInfo)

    & $csc @cscArgs
    if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath $assemblyInfo -Force -ErrorAction SilentlyContinue
}

$info = Get-Item -LiteralPath $out
Write-Host ("  built {0} ({1:N0} bytes)" -f $info.Name, $info.Length) -ForegroundColor Green
Write-Host ("  shows in the menu as '{0}'" -f $info.VersionInfo.FileDescription) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  The Platform launches this with no arguments, which runs the update check.' -ForegroundColor DarkGray
Write-Host '  Right-click it in the menu and tick "Start Automatically" for prompt-on-launch.' -ForegroundColor DarkGray
Write-Host ''
