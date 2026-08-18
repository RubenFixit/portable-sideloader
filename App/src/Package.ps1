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

function Write-TransferProgress {
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][long]$Completed,
        [Parameter(Mandatory)][long]$Total,
        [Parameter(Mandatory)][Diagnostics.Stopwatch]$Timer,
        [string]$Item = ''
    )

    $percent = if ($Total -gt 0) { [math]::Min(100, [math]::Floor(100 * $Completed / $Total)) } else { 0 }
    $eta = '--:--'
    if ($Completed -gt 0 -and $Timer.Elapsed.TotalSeconds -gt 0 -and $Total -gt $Completed) {
        $seconds = $Timer.Elapsed.TotalSeconds * (($Total - $Completed) / [double]$Completed)
        $eta = ([TimeSpan]::FromSeconds($seconds)).ToString('hh\:mm\:ss')
    }
    $status = if ($Item) { "$Item  |  ETA $eta" } else { "ETA $eta" }
    Write-Progress -Activity $Activity -Status $status -PercentComplete $percent
}

function Complete-TransferProgress {
    param([string]$Activity)
    Write-Progress -Activity $Activity -Completed
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
        $zip = $null
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
            $entries = @($zip.Entries)
            $total = [long](($entries | Where-Object { -not $_.FullName.EndsWith('/') } |
                Measure-Object -Property Length -Sum).Sum)
            $done = [long]0
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $lastProgress = [long]0
            $root = ([IO.Path]::GetFullPath($DestinationDir)).TrimEnd('\') + '\'

            foreach ($entry in $entries) {
                $target = [IO.Path]::GetFullPath((Join-Path $DestinationDir $entry.FullName))
                if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Archive entry escapes extraction directory: $($entry.FullName)"
                }
                if ($entry.FullName.EndsWith('/')) {
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                    continue
                }

                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                $input = $entry.Open()
                $output = [IO.File]::Open($target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buffer = New-Object byte[] 1048576
                    while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $output.Write($buffer, 0, $read)
                        $done += $read
                        if ($timer.ElapsedMilliseconds - $lastProgress -ge 150) {
                            Write-TransferProgress -Activity 'Extracting package' -Completed $done -Total $total `
                                -Timer $timer -Item ([IO.Path]::GetFileName($entry.FullName))
                            $lastProgress = $timer.ElapsedMilliseconds
                        }
                    }
                } finally {
                    $output.Dispose()
                    $input.Dispose()
                }
            }
            $timer.Stop()
            Write-TransferProgress -Activity 'Extracting package' -Completed $total -Total $total -Timer $timer
            Complete-TransferProgress -Activity 'Extracting package'
            return $DestinationDir
        } catch {
            if ($zip) { $zip.Dispose() }
            Write-Verbose "ZIP extraction failed ($($_.Exception.Message)); falling back to 7-Zip."
        } finally {
            if ($zip) { $zip.Dispose() }
        }
    }

    if (-not $SevenZip) {
        throw "7-Zip is required to extract '$([IO.Path]::GetFileName($ArchivePath))' but was not found. Install 7-Zip, or add 7-ZipPortable to your PortableApps folder."
    }

    Write-Progress -Activity 'Extracting package' -Status 'starting extraction...' -PercentComplete 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastPercent = 0
    $stdout = @(& $SevenZip x $ArchivePath "-o$DestinationDir" -y -bsp1 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if ($line -match '(?<percent>\d{1,3})%') {
            $lastPercent = [int]$Matches.percent
            $eta = '--:--'
            if ($lastPercent -gt 0 -and $lastPercent -lt 100 -and $timer.Elapsed.TotalSeconds -gt 0) {
                $seconds = $timer.Elapsed.TotalSeconds * ((100 - $lastPercent) / [double]$lastPercent)
                $eta = ([TimeSpan]::FromSeconds($seconds)).ToString('hh\:mm\:ss')
            }
            Write-Progress -Activity 'Extracting package' -Status "$lastPercent%  |  ETA $eta" -PercentComplete $lastPercent
        } else { $_ }
    })
    $timer.Stop()
    Complete-TransferProgress -Activity 'Extracting package'
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
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Activity = 'Copying files'
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $directories = @(Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($directory in $directories) {
        $relative = $directory.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        New-Item -ItemType Directory -Path (Join-Path $Destination $relative) -Force | Out-Null
    }

    $files = @(Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue)
    $total = [long](($files | Measure-Object -Property Length -Sum).Sum)
    $done = [long]0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        $destinationFile = Join-Path $Destination $relative
        $parent = Split-Path -Parent $destinationFile
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $destinationFile -Force
        $done += $file.Length
        Write-TransferProgress -Activity $Activity -Completed $done -Total $total -Timer $timer `
            -Item $relative
    }
    $timer.Stop()
    Complete-TransferProgress -Activity $Activity
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
    Copy-DirectoryContent -Source $AppDir -Destination $target -Activity 'Backing up app'
    return $target
}

function Get-AppBackups {
    # Newest first. Timestamps are the folder names written by Backup-App.
    param([Parameter(Mandatory)][string]$BackupRoot, [Parameter(Mandatory)][string]$Id)

    $dir = Join-Path $BackupRoot $Id
    if (-not (Test-Path -LiteralPath $dir)) { return @() }

    return @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object {
            $bytes = (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            [pscustomobject]@{
                Timestamp = $_.Name
                Path      = $_.FullName
                SizeMB    = [math]::Round(([double]$bytes) / 1MB, 1)
            }
        })
}

function Restore-AppBackup {
    <#
        Replaces the app folder with a backup wholesale - user data included, because rolling back
        a bad update usually means wanting the state that worked. The caller takes a fresh backup
        of the current folder first, so a restore is itself reversible.
    #>
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$AppDir
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) { throw "Backup not found: $BackupPath" }

    if (Test-Path -LiteralPath $AppDir) {
        Get-ChildItem -LiteralPath $AppDir -Force | Remove-Item -Recurse -Force
    } else {
        New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
    }
    Copy-DirectoryContent -Source $BackupPath -Destination $AppDir
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
