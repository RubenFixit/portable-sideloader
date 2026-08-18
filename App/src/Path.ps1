# User PATH management for installed PortableApps.

function Get-AppExecutableDirectory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Id,
        [string]$Name,
        [string]$Exe
    )

    $appDir = Join-Path $Root $Id
    if (-not (Test-Path -LiteralPath $appDir -PathType Container)) {
        $match = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq $Id } | Select-Object -First 1
        if ($match) { $appDir = $match.FullName }
    }
    if (-not (Test-Path -LiteralPath $appDir -PathType Container)) {
        throw "PortableApps app folder not found: $Id"
    }

    $exeFile = Get-MainExecutable -AppDir $appDir -Name $(if ($Name) { $Name } else { $Id }) -Exe $Exe
    if (-not $exeFile) {
        throw "No executable found for '$Id' under $appDir"
    }
    return $exeFile.Directory.FullName
}

function Add-UserPathEntry {
    param([Parameter(Mandatory)][string]$Directory)

    $full = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path.TrimEnd('\')
    $raw = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $existing = $entries | Where-Object {
        try { [IO.Path]::GetFullPath($_).TrimEnd('\') -ieq $full } catch { $_ -ieq $full }
    } | Select-Object -First 1

    if ($existing) {
        Write-Host "    already in user PATH: $full" -ForegroundColor DarkGray
        return $false
    }

    $newPath = (@($entries) + $full) -join ';'
    if ($DryRun) {
        Write-Host "    -DryRun: would add to user PATH: $full" -ForegroundColor DarkGray
        return $true
    }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "    added to user PATH: $full" -ForegroundColor Green
    return $true
}

function ConvertTo-ComparablePath {
    param([Parameter(Mandatory)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    try { return [IO.Path]::GetFullPath($expanded).TrimEnd('\') } catch { return $expanded.TrimEnd('\') }
}

function Remove-UserPathEntries {
    param(
        [string[]]$Directories,
        [string]$UnderDirectory
    )

    $raw = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $targets = @($Directories | Where-Object { $_ } | ForEach-Object { ConvertTo-ComparablePath $_ })
    $under = if ($UnderDirectory) { ConvertTo-ComparablePath $UnderDirectory } else { $null }
    $removed = @($entries | Where-Object {
        $current = ConvertTo-ComparablePath $_
        ($targets -contains $current) -or ($under -and ($current -ieq $under -or $current.StartsWith($under + '\', [StringComparison]::OrdinalIgnoreCase)))
    })

    if ($removed.Count -eq 0) {
        if ($under) { Write-Host "    no user PATH entries found under: $under" -ForegroundColor DarkGray }
        return $false
    }

    $remaining = @($entries | Where-Object { $removed -notcontains $_ })
    if ($DryRun) {
        foreach ($entry in $removed) { Write-Host "    -DryRun: would remove from user PATH: $entry" -ForegroundColor DarkGray }
        return $true
    }

    [Environment]::SetEnvironmentVariable('Path', ($remaining -join ';'), 'User')
    foreach ($entry in $removed) { Write-Host "    removed from user PATH: $entry" -ForegroundColor Green }
    Invoke-RefreshEnvironment | Out-Null
    return $true
}

function Remove-AppPathEntries {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Paths
    )

    $id = Get-Prop $Entry 'id'
    if ($Paths -and $Paths.Count -gt 0) {
        $targets = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object {
            $_
        } | ForEach-Object {
            if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Root $_ }
        })
        Remove-UserPathEntries -Directories $targets | Out-Null
        return
    }

    Remove-UserPathEntries -UnderDirectory (Join-Path $Root $id) | Out-Null
}

function Invoke-RefreshEnvironment {
    # Chocolatey's PowerShell helper refreshes the current process from the registry. This is
    # useful for commands launched by sideloader and for dot-sourced use; an executable cannot
    # change the environment of the already-running parent PowerShell process.
    $module = if ($env:ChocolateyInstall) {
        Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
    }
    if (-not $module -or -not (Test-Path -LiteralPath $module)) { return $false }

    try {
        Import-Module -Name $module -ErrorAction Stop
        Update-SessionEnvironment
        Write-Host '    refreshed this process with Chocolatey refreshenv' -ForegroundColor DarkGray
        Write-Host '    reopen the invoking terminal for its PATH to change' -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Warning "PATH was saved, but Chocolatey refreshenv failed: $($_.Exception.Message)"
        return $false
    }
}

function Add-AppExecutableToPath {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Root,
        [switch]$Prompt
    )

    $id = Get-Prop $Entry 'id'
    $name = Get-Prop $Entry 'name' $id
    $exe = Get-Prop $Entry 'exe'
    $directory = Get-AppExecutableDirectory -Root $Root -Id $id -Name $name -Exe $exe
    if ($Prompt -and -not $AddToPath -and -not (Confirm-Action "Add $id to your user PATH?")) { return }
    $changed = Add-UserPathEntry -Directory $directory
    if ($changed -and -not $DryRun) { Invoke-RefreshEnvironment | Out-Null }
}

function Add-AppPathEntries {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Paths
    )

    if (-not $Paths -or $Paths.Count -eq 0) {
        Add-AppExecutableToPath -Entry $Entry -Root $Root
        return
    }

    $changed = $false
    foreach ($path in @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $directory = if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $Root $path }
        $changed = (Add-UserPathEntry -Directory $directory) -or $changed
    }
    if ($changed -and -not $DryRun) { Invoke-RefreshEnvironment | Out-Null }
}
