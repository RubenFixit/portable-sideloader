#Requires -Version 5.1

# Download, verify, extract, and swap payloads. Everything destructive lives in this file.

function Find-SevenZip {
    <#
        PATH first, then each path in config.json's settings.sevenZipPaths. Those support
        %ENVVAR% and the <root> placeholder, so a USB stick carrying 7-ZipPortable keeps working
        on a machine with no 7-Zip installed.
    #>
    param([string]$PortableAppsRoot, [string[]]$SearchPaths)

    $cmd = Get-Command 7z.exe, 7za.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    foreach ($raw in @($SearchPaths)) {
        if (-not $raw) { continue }
        $path = [Environment]::ExpandEnvironmentVariables($raw)
        if ($PortableAppsRoot) { $path = $path.Replace('<root>', $PortableAppsRoot) }
        if ($path -match '%\w+%' -or $path -match '<root>') { continue }   # unresolved placeholder
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Get-DownloadUri {
    # Scoop appends "#/name.ext" to rename a download; that fragment is not part of the request.
    param([Parameter(Mandatory)][string]$Url)
    return ($Url -split '#')[0]
}

function Get-DownloadFileName {
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -match '#/(.+)$') { return $Matches[1] }
    $name = [IO.Path]::GetFileName(([uri](Get-DownloadUri $Url)).AbsolutePath)
    if (-not $name) { $name = 'download.bin' }
    return $name
}

function Invoke-PackageDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$CacheDir,
        [string]$ExpectedSha256,
        [int]$TimeoutSec = 300
    )

    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }
    $target = Join-Path $CacheDir (Get-DownloadFileName $Url)

    if ((Test-Path -LiteralPath $target) -and $ExpectedSha256) {
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $ExpectedSha256.ToUpperInvariant()) {
            Write-Verbose "Cache hit: $target"
            return $target
        }
    }

    Write-Host "    downloading $(Split-Path -Leaf $target)..." -ForegroundColor DarkGray
    Invoke-WebRequest -Uri (Get-DownloadUri $Url) -OutFile $target -UseBasicParsing `
        -Headers (Get-RequestHeaders) -TimeoutSec $TimeoutSec

    if ($ExpectedSha256) {
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($actual -ne $ExpectedSha256.ToUpperInvariant()) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            throw "SHA256 mismatch. Expected $($ExpectedSha256.ToUpperInvariant()), got $actual. Download discarded."
        }
        Write-Verbose 'SHA256 verified.'
    } else {
        Write-Warning '    no hash published for this source; integrity not verified'
    }

    return $target
}

function Expand-Package {
    <#
        Returns the directory holding the extracted payload. A download that is not an archive
        at all (a bare portable .exe, for instance) is copied through as-is.
    #>
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationDir,
        [string]$SevenZip
    )

    if (Test-Path -LiteralPath $DestinationDir) {
        Remove-Item -LiteralPath $DestinationDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null

    $ext = [IO.Path]::GetExtension($ArchivePath).ToLowerInvariant()

    if ($ext -eq '.zip') {
        try {
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationDir -Force
            return $DestinationDir
        } catch {
            Write-Verbose "Expand-Archive failed ($($_.Exception.Message)); falling back to 7-Zip."
        }
    }

    if (-not $SevenZip) {
        throw "7-Zip is required to extract '$([IO.Path]::GetFileName($ArchivePath))' but was not found. Install 7-Zip, or add 7-ZipPortable to your PortableApps folder."
    }

    $stdout = & $SevenZip x $ArchivePath "-o$DestinationDir" -y 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Not an archive - treat the download as the payload itself.
        $produced = @(Get-ChildItem -LiteralPath $DestinationDir -Force -ErrorAction SilentlyContinue)
        if ($produced.Count -eq 0) {
            Write-Verbose "7-Zip could not open the file; treating it as a single-file payload."
            Copy-Item -LiteralPath $ArchivePath -Destination $DestinationDir -Force
            return $DestinationDir
        }
        throw "7-Zip failed (exit $LASTEXITCODE): $($stdout | Select-Object -Last 3)"
    }

    return $DestinationDir
}

function Resolve-PayloadRoot {
    # Most archives wrap everything in one top-level folder; publish its contents, not the wrapper.
    param([Parameter(Mandatory)][string]$Dir)
    $children = @(Get-ChildItem -LiteralPath $Dir -Force)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
        return $children[0].FullName
    }
    return $Dir
}

function Get-SideloadMarker {
    param([Parameter(Mandatory)][string]$AppDir)
    $path = Join-Path $AppDir '.sideload.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Set-SideloadMarker {
    <#
        Records the authoritative installed version. This exists because several sideloaded apps
        ship executables with no version resource at all (OpenSCAD and OrcaSlicer, for two), which
        leaves nothing to compare against. Deliberately not appinfo.ini: writing that would make
        the Platform treat a flat folder as a PAF app and expect a layout it does not have.
    #>
    param(
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Version,
        [string]$Provider,
        [string]$Url,
        [string]$Sha256
    )
    [pscustomobject]@{
        id          = $Id
        version     = $Version
        provider    = $Provider
        url         = $Url
        sha256      = $Sha256
        installedUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $AppDir '.sideload.json') -Encoding UTF8
}

function Copy-DirectoryContent {
    # Copies the *contents* of a directory. Deliberately enumerates rather than using a "\*"
    # glob: -LiteralPath does not expand wildcards, and -Path would misread names containing
    # [ or ] as character classes.
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Backup-App {
    param(
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not (Test-Path -LiteralPath $AppDir)) { return $null }

    $stamp  = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $target = Join-Path (Join-Path $BackupRoot $Id) $stamp
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-DirectoryContent -Source $AppDir -Destination $target
    return $target
}

function Install-Payload {
    <#
        Replaces the app's program files while preserving user data. Preserved paths are moved
        aside, the old payload is deleted, the new one is moved in, then the preserved paths are
        restored over the top.
    #>
    param(
        [Parameter(Mandatory)][string]$PayloadDir,
        [Parameter(Mandatory)][string]$AppDir,
        [string[]]$Preserve = @()
    )

    $stash = Join-Path ([IO.Path]::GetTempPath()) ("sideload-preserve-" + [guid]::NewGuid().ToString('N'))
    $saved = @()

    if (Test-Path -LiteralPath $AppDir) {
        foreach ($rel in $Preserve) {
            $src = Join-Path $AppDir $rel
            if (Test-Path -LiteralPath $src) {
                $dst = Join-Path $stash $rel
                New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
                Move-Item -LiteralPath $src -Destination $dst -Force
                $saved += $rel
            }
        }
        Get-ChildItem -LiteralPath $AppDir -Force | Remove-Item -Recurse -Force
    } else {
        New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
    }

    Copy-DirectoryContent -Source $PayloadDir -Destination $AppDir

    foreach ($rel in $saved) {
        $src = Join-Path $stash $rel
        $dst = Join-Path $AppDir $rel
        $parent = Split-Path -Parent $dst
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Move-Item -LiteralPath $src -Destination $dst -Force
    }

    if (Test-Path -LiteralPath $stash) { Remove-Item -LiteralPath $stash -Recurse -Force -ErrorAction SilentlyContinue }
    return , ([string[]]$saved)
}
