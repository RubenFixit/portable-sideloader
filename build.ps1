#Requires -Version 5.1
<#
.SYNOPSIS
    Compile the launcher stub.

.DESCRIPTION
    Uses the C# compiler that ships with the .NET Framework on every Windows install, so building
    needs no SDK, no package manager, and no admin rights.

    Output lands at the package root, next to App\ and Data\, which is where the Platform expects
    an app's executable to be.

.EXAMPLE
    .\build.ps1

.EXAMPLE
    .\build.ps1 -Name MyLauncher -IconPath .\icon.ico
#>
[CmdletBinding()]
param(
    [string] $Name       = 'PortableSideloader',
    [string] $OutputDir  = $PSScriptRoot,
    [string] $SourcePath = (Join-Path $PSScriptRoot 'App\Launcher\Launcher.cs'),
    [string] $IconPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

if (-not (Test-Path -LiteralPath $SourcePath)) { throw "Source not found: $SourcePath" }

$csc = Find-CSharpCompiler
$out = Join-Path $OutputDir "$Name.exe"

Write-Host ''
Write-Host "  compiler  $csc" -ForegroundColor DarkGray
Write-Host "  source    $SourcePath" -ForegroundColor DarkGray
Write-Host "  output    $out" -ForegroundColor DarkGray
Write-Host ''

$cscArgs = @('/nologo', '/target:exe', '/platform:anycpu', '/optimize+', "/out:$out")
if ($IconPath) {
    if (-not (Test-Path -LiteralPath $IconPath)) { throw "Icon not found: $IconPath" }
    $cscArgs += "/win32icon:$IconPath"
}
$cscArgs += $SourcePath

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }

$info = Get-Item -LiteralPath $out
Write-Host ("  built {0} ({1:N0} bytes)" -f $info.Name, $info.Length) -ForegroundColor Green
Write-Host ''
Write-Host '  The Platform launches this with no arguments, which runs the update check.' -ForegroundColor DarkGray
Write-Host '  Right-click it in the menu and tick "Start Automatically" for prompt-on-launch.' -ForegroundColor DarkGray
Write-Host ''
