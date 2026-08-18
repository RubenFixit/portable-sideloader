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
