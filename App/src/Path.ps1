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
    Write-Host '    open a new terminal for the PATH change to take effect there' -ForegroundColor DarkGray
    return $true
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
    Add-UserPathEntry -Directory $directory | Out-Null
}
