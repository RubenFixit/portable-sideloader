#Requires -Version 5.1
<#
.SYNOPSIS
    Manage apps sideloaded into a PortableApps.com menu - the ones the official updater skips.

.DESCRIPTION
    Commands:
      ls                      List managed apps and their installed versions (offline).
      search <term>           Search the Scoop buckets for an installable app.
      show <app>              Everything known about one app, including the upstream version.
      install <name>          Add an app and install it into the PortableApps folder.
      update [app]            Check for updates and apply them, prompting per app.
      remove <app>            Uninstall an app and stop managing it.

.EXAMPLE
    .\sideload.ps1 ls

.EXAMPLE
    .\sideload.ps1 search slicer

.EXAMPLE
    .\sideload.ps1 update -DryRun

.EXAMPLE
    .\sideload.ps1 install orcaslicer

.EXAMPLE
    .\sideload.ps1 remove UserBenchMark -KeepData
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('ls', 'list', 'search', 'show', 'explain', 'add', 'install', 'update', 'remove', 'categorize', 'help')]
    [string]   $Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Name,

    # Code lives in App\ and is replaced wholesale on update; everything you own lives in Data\.
    [string]   $DataDir      = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data'),
    [string]   $ConfigPath   = (Join-Path $PSScriptRoot 'config.json'),
    [string]   $LocalConfigPath,
    [string]   $ManifestPath,

    # Everything below falls back to config.json when not supplied.
    [string]   $PortableAppsRoot,
    [string]   $StatePath,
    [string]   $CacheDir,
    [string]   $BackupRoot,
    [int]      $TimeoutSec,
    [int]      $StaleDays,

    # install / add
    [string]   $Bucket,
    [string]   $Id,
    [string]   $DisplayName,
    [string]   $WatchUrl,
    [string]   $VersionPattern,
    [string[]] $Preserve,
    [string]   $Category,

    [switch]   $Import,
    [switch]   $DryRun,
    [switch]   $Yes,
    [switch]   $KeepData,
    [switch]   $NoBackup,
    [switch]   $Refresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'src\Common.ps1')
. (Join-Path $PSScriptRoot 'src\Providers.ps1')
. (Join-Path $PSScriptRoot 'src\Registry.ps1')
. (Join-Path $PSScriptRoot 'src\Package.ps1')
. (Join-Path $PSScriptRoot 'src\Infer.ps1')
. (Join-Path $PSScriptRoot 'src\PlatformMenu.ps1')

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$script:PackageRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
if (-not $LocalConfigPath) { $LocalConfigPath = Join-Path $DataDir 'config.local.json' }
if (-not $ManifestPath)    { $ManifestPath    = Join-Path $DataDir 'apps.json' }

$script:Cfg = Get-Config -Path $ConfigPath -LocalPath $LocalConfigPath
Set-ProviderConfig -Config $script:Cfg

function Resolve-ConfigPath {
    # Relative paths from config.json resolve under Data\, never next to the code.
    param([string]$Value, [string]$Fallback)
    $v = if ($Value) { $Value } else { $Fallback }
    if ([IO.Path]::IsPathRooted($v)) { return $v }
    return (Join-Path $DataDir $v)
}

$sevenZipPaths  = @(Get-Setting $script:Cfg 'sevenZipPaths' $null @())
$CacheDir       = Resolve-ConfigPath $CacheDir   (Get-Setting $script:Cfg 'cacheDir'   $null 'cache')
$BackupRoot     = Resolve-ConfigPath $BackupRoot (Get-Setting $script:Cfg 'backupRoot' $null 'backups')
$StatePath      = Resolve-ConfigPath $StatePath  (Get-Setting $script:Cfg 'statePath'  $null 'state.json')
$TimeoutSec     = [int](Get-Setting $script:Cfg 'timeoutSec'       $TimeoutSec 30)
$StaleDays      = [int](Get-Setting $script:Cfg 'staleDays'        $StaleDays 180)
$dlTimeoutSec   = [int](Get-Setting $script:Cfg 'downloadTimeoutSec' $null 600)
$bucketCacheHrs = [int](Get-Setting $script:Cfg 'bucketCacheHours'   $null 24)

$script:StatusColor = @{
    UpdateAvailable = 'Yellow'
    UpToDate        = 'Green'
    Differs         = 'Magenta'
    NoBaseline      = 'DarkYellow'
    Unknown         = 'Red'
    MissingFolder   = 'Red'
}

#region helpers ---------------------------------------------------------------

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ''
}

function Confirm-Action {
    param([string]$Prompt, [switch]$DefaultYes)
    if ($Yes) { return $true }
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "    $Prompt $suffix"
    if (-not $answer) { return [bool]$DefaultYes }
    return $answer -match '^(y|yes)$'
}

function Resolve-Upstream {
    param($Entry)
    $provider = Get-Prop $Entry 'provider' 'todo'
    try {
        $up = Get-LatestVersion -Provider $provider -Source (Get-Prop $Entry 'source') -TimeoutSec $TimeoutSec
        return [pscustomobject]@{
            Version = Get-Prop $up 'Version'
            Url     = Get-Prop $up 'Url'
            Hash    = Get-Prop $up 'Hash'
            Persist = @(Get-Prop $up 'Persist' @())
            Origin  = Get-Prop $up 'Origin' $provider
            Error   = if (Get-Prop $up 'Version') { '' } else { 'provider returned no version' }
        }
    } catch {
        return [pscustomobject]@{
            Version = $null; Url = $null; Hash = $null; Persist = @()
            Origin = $provider; Error = $_.Exception.Message
        }
    }
}

function Test-SelfEntry {
    param($Entry)
    return [bool](Get-Prop $Entry 'self' $false)
}

function Get-AppFolder {
    # A self entry owns the package this script is running from, wherever that happens to be -
    # a dev checkout outside the PortableApps tree still resolves correctly.
    param($Entry, [string]$Root)
    if (Test-SelfEntry $Entry) { return $script:PackageRoot }
    return (Join-Path $Root $Entry.id)
}

function Get-AppRow {
    param($Entry, [string]$Root, [switch]$Online)

    $id     = $Entry.id
    $name   = Get-Prop $Entry 'name' $id
    $appDir = Get-AppFolder -Entry $Entry -Root $Root

    # Our own version is shipped in App\VERSION rather than sniffed from a binary.
    if (Test-SelfEntry $Entry) {
        # Fall back to 0 rather than $null when VERSION is absent. A null would report NoBaseline,
        # which never triggers an update - so a build that shipped without the file could never
        # replace itself. Reporting 0 makes any release newer, and the next update self-heals.
        $versionFile = Join-Path $PSScriptRoot 'VERSION'
        $selfVersion = if (Test-Path -LiteralPath $versionFile) {
            (Get-Content -LiteralPath $versionFile -Raw).Trim()
        } else { '0' }
        $selfFrom = if (Test-Path -LiteralPath $versionFile) { 'App\VERSION' }
                    else { 'App\VERSION missing, assuming 0' }

        $selfUp = if ($Online) { Resolve-Upstream -Entry $Entry } else { $null }
        return [pscustomobject]@{
            App = $id; Name = $name; AppDir = $appDir
            Installed = $selfVersion
            InstalledFrom = $selfFrom
            Heuristic = $false
            Latest = if ($selfUp) { $selfUp.Version } else { $null }
            Status = if ($Online) { Compare-AppVersion -Installed $selfVersion -Latest $selfUp.Version } else { 'Local' }
            Detail = if ($selfUp) { $selfUp.Error } else { '' }
            Provider = Get-Prop $Entry 'provider' 'todo'
            Upstream = $selfUp
            Notes = Get-Prop $Entry 'notes' ''
        }
    }

    $installed = $null; $from = ''; $heuristic = $false
    if (Test-Path -LiteralPath $appDir) {
        $found = Get-InstalledVersion -AppDir $appDir -Name $name -Exe (Get-Prop $Entry 'exe')
        if ($found) {
            $installed = $found.Version; $from = $found.Source; $heuristic = $found.Heuristic
        } else {
            $anyExe = Get-ChildItem -LiteralPath $appDir -Filter *.exe -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            $from = if ($anyExe) { 'exe carries no version resource' } else { 'no program files in folder' }
        }
    } else {
        $from = 'missing folder'
    }

    $up = if ($Online) { Resolve-Upstream -Entry $Entry } else { $null }

    $status = if ($Online) { Compare-AppVersion -Installed $installed -Latest $up.Version } else { 'Local' }
    if (-not (Test-Path -LiteralPath $appDir)) { $status = 'MissingFolder' }

    $detail = if ($up) { $up.Error } else { '' }
    if ($status -eq 'NoBaseline' -and -not $detail) { $detail = $from }

    return [pscustomobject]@{
        App = $id; Name = $name; AppDir = $appDir
        Installed = $installed; InstalledFrom = $from; Heuristic = $heuristic
        Latest = if ($up) { $up.Version } else { $null }
        Status = $status; Detail = $detail
        Provider = Get-Prop $Entry 'provider' 'todo'
        Upstream = $up
        Notes = Get-Prop $Entry 'notes' ''
    }
}

function Write-Row {
    param($Row, [int]$Width)
    $inst = if ($Row.Installed) { $Row.Installed } else { '-' }
    if ($Row.Heuristic) { $inst += '*' }
    if ($inst.Length -gt 24) { $inst = $inst.Substring(0, 21) + '...' }
    $late = if ($Row.Latest) { $Row.Latest } else { '-' }

    Write-Host ("  {0}  " -f $Row.App.PadRight($Width)) -NoNewline
    Write-Host ("{0}  ->  {1}  " -f $inst.PadRight(24), $late.PadRight(16)) -NoNewline -ForegroundColor Gray
    Write-Host $Row.Status -NoNewline -ForegroundColor $script:StatusColor[$Row.Status]
    if ($Row.Detail) { Write-Host "  ($($Row.Detail))" -NoNewline -ForegroundColor DarkGray }
    Write-Host ''
}

function Get-PreserveList {
    # The unary comma is load-bearing: PowerShell unrolls a one-element array on return, which
    # would hand the caller a bare string and break .Count under Set-StrictMode.
    param($Entry, $Upstream)
    $explicit = @(Get-Prop $Entry 'preserve' $null) | Where-Object { $_ }
    if (@($explicit).Count -gt 0) { return , ([string[]]@($explicit)) }
    if ($Upstream) {
        $persist = @(Get-Prop $Upstream 'Persist' $null) | Where-Object { $_ }
        return , ([string[]]@($persist))
    }
    return , ([string[]]@())
}

function Invoke-AppInstall {
    <#
        Shared by `install` and `update`. Downloads, verifies, extracts, backs up, swaps,
        then records the version in .sideload.json.
    #>
    param($Entry, $Upstream, [string]$Root, [switch]$IsUpdate)

    $id     = $Entry.id
    $appDir = Get-AppFolder -Entry $Entry -Root $Root

    # The Platform keys categories, renames and hidden flags by "folder\exe.exe", so an update
    # that renames the executable silently drops all three back to default.
    $exeBefore = $null
    if ($IsUpdate) {
        $found = Get-MainExecutable -AppDir $appDir -Name (Get-Prop $Entry 'name' $id) -Exe (Get-Prop $Entry 'exe')
        if ($found) { $exeBefore = $found.Name }
    }

    if (-not $Upstream.Url) {
        throw "No download URL resolved for '$id' (provider $($Entry.provider)). Version detection works, but the source has no usable asset."
    }

    $sevenZip = Find-SevenZip -PortableAppsRoot $Root -SearchPaths $sevenZipPaths
    $archive  = Invoke-PackageDownload -Url $Upstream.Url -CacheDir $CacheDir `
                    -ExpectedSha256 $Upstream.Hash -TimeoutSec $dlTimeoutSec

    $stagingDir = Join-Path $CacheDir "staging\$id"
    Write-Host '    extracting...' -ForegroundColor DarkGray
    $extracted = Expand-Package -ArchivePath $archive -DestinationDir $stagingDir -SevenZip $sevenZip
    $payload   = Resolve-PayloadRoot -Dir $extracted

    # Updating ourselves cannot swap in place: this process holds App\*.ps1 and the launcher holds
    # the .exe. Stage the payload instead and let the launcher apply it before anything loads.
    if (Test-SelfEntry $Entry) {
        $updateDir = Join-Path $DataDir 'update'
        if (Test-Path -LiteralPath $updateDir) { Remove-Item -LiteralPath $updateDir -Recurse -Force }
        New-Item -ItemType Directory -Path $updateDir -Force | Out-Null
        Copy-DirectoryContent -Source $payload -Destination $updateDir
        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Version = $Upstream.Version; Backup = $null; Preserved = @()
            RenamedExe = $null; Staged = $updateDir
        }
    }

    $backup = $null
    if ($IsUpdate -and -not $NoBackup) {
        Write-Host '    backing up...' -ForegroundColor DarkGray
        $backup = Backup-App -AppDir $appDir -BackupRoot $BackupRoot -Id $id
    }

    # No @() wrap here - Get-PreserveList already returns an array, and re-wrapping would nest it.
    $preserve = Get-PreserveList -Entry $Entry -Upstream $Upstream
    if ($preserve.Count -gt 0) {
        Write-Host "    preserving: $($preserve -join ', ')" -ForegroundColor DarkGray
    }

    $kept = Install-Payload -PayloadDir $payload -AppDir $appDir -Preserve $preserve
    Set-SideloadMarker -AppDir $appDir -Id $id -Version $Upstream.Version `
        -Provider (Get-Prop $Entry 'provider') -Url $Upstream.Url -Sha256 $Upstream.Hash

    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

    $renamedExe = $null
    if ($exeBefore) {
        $after = Get-MainExecutable -AppDir $appDir -Name (Get-Prop $Entry 'name' $id) -Exe (Get-Prop $Entry 'exe')
        if ($after -and $after.Name -ne $exeBefore) { $renamedExe = "$exeBefore -> $($after.Name)" }
    }

    return [pscustomobject]@{
        Version = $Upstream.Version; Backup = $backup; Preserved = $kept
        RenamedExe = $renamedExe; Staged = $null
    }
}

#endregion

#region commands --------------------------------------------------------------

function Invoke-Ls {
    param($Manifest, [string]$Root)
    $all = @($Manifest.apps)
    $entries = $all
    if ($Name) { $entries = @($entries | Where-Object { $Name -contains $_.id }) }

    if ($all.Count -eq 0) {
        Write-Head 'no apps managed yet'
        Write-Host '  Add one from a bucket, or straight from a download URL:' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    .\sideload.ps1 search slicer' -ForegroundColor White
        Write-Host '    .\sideload.ps1 install orcaslicer' -ForegroundColor White
        Write-Host '    .\sideload.ps1 install https://example.com/app-1.2.3.zip' -ForegroundColor White
        Write-Host ''
        Write-Host '  Already have folders in your PortableApps directory? Register one without' -ForegroundColor DarkGray
        Write-Host '  downloading, then pull your existing menu categories in:' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    .\sideload.ps1 add <url> -Id <FolderName>' -ForegroundColor White
        Write-Host '    .\sideload.ps1 categorize -Import' -ForegroundColor White
        Write-Host ''
        return
    }
    if ($entries.Count -eq 0) { Write-Warning "No managed app matches: $($Name -join ', ')"; return }

    Write-Head "$($entries.Count) managed app(s) in $Root"
    $rows = @($entries | ForEach-Object { Get-AppRow -Entry $_ -Root $Root })
    $w = ($rows | ForEach-Object { $_.App.Length } | Measure-Object -Maximum).Maximum

    foreach ($r in $rows) {
        $inst = if ($r.Installed) { $r.Installed } else { '-' }
        if ($r.Heuristic) { $inst += '*' }
        if ($inst.Length -gt 24) { $inst = $inst.Substring(0, 21) + '...' }
        Write-Host ("  {0}  " -f $r.App.PadRight($w)) -NoNewline
        Write-Host $inst.PadRight(26) -NoNewline -ForegroundColor Gray
        Write-Host $r.Provider -NoNewline -ForegroundColor DarkCyan
        if ($r.InstalledFrom -and -not $r.Installed) {
            Write-Host "  ($($r.InstalledFrom))" -NoNewline -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    Write-Host ''
    Write-Host '  * version read from an exe resource, not authoritative' -ForegroundColor DarkGray
    Write-Host "  run 'update -DryRun' to compare against upstream" -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-Search {
    if (-not $Name) { throw "search needs a term, e.g. .\sideload.ps1 search slicer" }
    $term  = $Name[0]
    $index = Get-BucketIndex -CachePath (Join-Path $CacheDir 'buckets.json') -Config $script:Cfg `
                 -MaxAgeHours $bucketCacheHrs -Force:$Refresh -TimeoutSec $TimeoutSec
    $hits  = Find-BucketManifest -Index $index -Term $term -Bucket $Bucket

    Write-Head "$($hits.Count) match(es) for '$term' across $($index.Count) Scoop manifests"
    if ($hits.Count -eq 0) {
        Write-Host "  Nothing found. The app may still be installable via the github or html provider." -ForegroundColor DarkGray
        Write-Host ''
        return
    }
    foreach ($h in ($hits | Select-Object -First 40)) {
        Write-Host ("  {0}  " -f $h.Name.PadRight(38)) -NoNewline
        Write-Host $h.Bucket -ForegroundColor DarkCyan
    }
    if ($hits.Count -gt 40) { Write-Host "  ... and $($hits.Count - 40) more" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host "  install with: .\sideload.ps1 install $($hits[0].Name)" -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-Show {
    param($Manifest, [string]$Root)
    if (-not $Name) { throw "show needs an app id, e.g. .\sideload.ps1 show OrcaSlicer" }

    foreach ($n in $Name) {
        $entry = Get-ManagedApp -Manifest $Manifest -Id $n
        if (-not $entry) { Write-Warning "'$n' is not managed. Try: .\sideload.ps1 ls"; continue }

        $row = Get-AppRow -Entry $entry -Root $Root -Online
        Write-Head $row.Name

        $pairs = [ordered]@{
            'Id'        = $row.App
            'Folder'    = $row.AppDir
            'Installed' = "$(if ($row.Installed) { $row.Installed } else { '(unknown)' })  [$($row.InstalledFrom)]"
            'Upstream'  = "$(if ($row.Latest) { $row.Latest } else { '(unresolved)' })  [$($row.Upstream.Origin)]"
            'Status'    = $row.Status
            'Provider'  = $row.Provider
            'Download'  = if ($row.Upstream.Url) { $row.Upstream.Url } else { '(none)' }
            'SHA256'    = if ($row.Upstream.Hash) { $row.Upstream.Hash } else { '(not published)' }
            'Preserves' = (Get-PreserveList -Entry $entry -Upstream $row.Upstream) -join ', '
        }
        foreach ($k in $pairs.Keys) {
            Write-Host ("    {0}  " -f $k.PadRight(11)) -NoNewline -ForegroundColor DarkGray
            Write-Host $pairs[$k]
        }
        if ($row.Detail) {
            Write-Host '    Problem      ' -NoNewline -ForegroundColor DarkGray
            Write-Host $row.Detail -ForegroundColor Yellow
        }
        if ($row.Notes) {
            Write-Host ''
            Write-Host "    $($row.Notes)" -ForegroundColor DarkGray
        }
        Write-Host ''
    }
}

function Show-Inference {
    param($Inferred, [string]$Url)
    Write-Host "    url        $Url" -ForegroundColor DarkGray
    Write-Host "    rule       $($Inferred.Rule)"
    Write-Host "    provider   $($Inferred.Provider)"
    if ($Inferred.DetectedVersion) {
        Write-Host "    version    $($Inferred.DetectedVersion)  (matched '$($Inferred.VersionPattern)')"
    }
    Write-Host '    source'
    foreach ($p in $Inferred.Source.PSObject.Properties) {
        Write-Host ("      {0}  " -f $p.Name.PadRight(16)) -NoNewline -ForegroundColor DarkGray
        Write-Host $p.Value
    }
    foreach ($w in @($Inferred.Warnings)) {
        Write-Host "    ! $w" -ForegroundColor Yellow
    }
}

function Invoke-Explain {
    if (-not $Name) { throw "explain needs a download URL, e.g. .\sideload.ps1 explain https://example.com/app-1.2.3.zip" }
    $url = $Name[0]

    Write-Head 'inferred source'
    $inferred = Resolve-SourceFromUrl -Url $url -Config $script:Cfg -WatchUrl $WatchUrl
    if ($VersionPattern) {
        $inferred.Source | Add-Member -NotePropertyName 'versionPattern' -NotePropertyValue $VersionPattern -Force
        $inferred.Warnings = @()
    }
    Show-Inference -Inferred $inferred -Url $url

    Write-Host ''
    Write-Host '    live check:' -ForegroundColor DarkGray
    $probe = Resolve-Upstream -Entry ([pscustomobject]@{ provider = $inferred.Provider; source = $inferred.Source })
    if ($probe.Version) {
        Write-Host "      resolves to $($probe.Version)" -ForegroundColor Green
        Write-Host "      $($probe.Url)" -ForegroundColor DarkGray
    } else {
        Write-Host "      failed: $($probe.Error)" -ForegroundColor Red
        Write-Host '      supply -WatchUrl and/or -VersionPattern, or add a host rule to config.json' -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Invoke-Add {
    <#
        Registers an app without downloading anything - for folders already sitting in the
        PortableApps directory. The next `update` will pick it up.
    #>
    param($Manifest, [string]$Root)
    if (-not $Name) { throw "add needs a download URL, e.g. .\sideload.ps1 add https://example.com/app-1.2.3.zip -Id MyApp" }
    $url = $Name[0]

    $appId = if ($Id) { $Id } elseif ($Name.Count -gt 1) { $Name[1] } else {
        throw 'add needs -Id to say which folder under the PortableApps root this app owns.'
    }
    if (Get-ManagedApp -Manifest $Manifest -Id $appId) { throw "'$appId' is already managed." }

    $built = New-AppEntryFromUrl -Url $url -Id $appId -Config $script:Cfg -DisplayName $DisplayName `
                 -WatchUrl $WatchUrl -VersionPattern $VersionPattern -Preserve $Preserve
    if ($Category) { $built.Entry | Add-Member -NotePropertyName 'category' -NotePropertyValue $Category -Force }

    Write-Head "add $appId"
    Show-Inference -Inferred $built.Inferred -Url $url
    Write-Host ''

    if ($DryRun) { Write-Host '    -DryRun: nothing written.' -ForegroundColor DarkGray; Write-Host ''; return }
    if (-not (Confirm-Action 'Register this app?' -DefaultYes)) { return }

    $null = Add-ManagedApp -Manifest $Manifest -Entry $built.Entry
    Save-AppManifest -Manifest $Manifest -Path $ManifestPath
    Write-Host "    registered in $ManifestPath" -ForegroundColor Green
    Write-Host "    run: .\sideload.ps1 update $appId" -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-InstallFromUrl {
    param($Manifest, [string]$Root, [string]$Url)

    $appId = if ($Id) { $Id } else {
        # Strip the version and extension off the filename for a reasonable default folder name.
        $base = [IO.Path]::GetFileNameWithoutExtension((Get-DownloadFileName $Url))
        ($base -replace '[-_.]?\d+([._-]\d+)*.*$', '') -replace '[^A-Za-z0-9._-]', ''
    }
    if (-not $appId) { throw 'Could not derive a folder name from the URL; pass -Id.' }
    if (Get-ManagedApp -Manifest $Manifest -Id $appId) {
        throw "'$appId' is already managed. Use 'update $appId', or pass -Id for a different folder name."
    }

    $built = New-AppEntryFromUrl -Url $Url -Id $appId -Config $script:Cfg -DisplayName $DisplayName `
                 -WatchUrl $WatchUrl -VersionPattern $VersionPattern -Preserve $Preserve
    if ($Category) { $built.Entry | Add-Member -NotePropertyName 'category' -NotePropertyValue $Category -Force }

    Write-Head "install $appId (from url)"
    Show-Inference -Inferred $built.Inferred -Url $Url
    Write-Host ''

    $up = Resolve-Upstream -Entry $built.Entry
    if (-not $up.Version) {
        Write-Host "    update detection failed: $($up.Error)" -ForegroundColor Yellow
        Write-Host '    the app can still be installed from this exact URL, but updates will not be tracked.' -ForegroundColor DarkGray
        $up = [pscustomobject]@{
            Version = if ($built.Inferred.DetectedVersion) { $built.Inferred.DetectedVersion } else { '0' }
            Url = $Url; Hash = $null; Persist = @(); Origin = 'literal url'; Error = ''
        }
    } else {
        Write-Host "    resolves to $($up.Version)" -ForegroundColor Green
    }
    Write-Host "    into  $(Join-Path $Root $appId)"
    Write-Host ''

    if ($DryRun) { Write-Host '    -DryRun: nothing written.' -ForegroundColor DarkGray; Write-Host ''; return }
    if (-not (Confirm-Action 'Proceed?' -DefaultYes)) { return }

    $result = Invoke-AppInstall -Entry $built.Entry -Upstream $up -Root $Root
    $null = Add-ManagedApp -Manifest $Manifest -Entry $built.Entry
    Save-AppManifest -Manifest $Manifest -Path $ManifestPath

    Write-Host ''
    Write-Host "    installed $appId $($result.Version)" -ForegroundColor Green
    Write-Host "    registered in $ManifestPath" -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-Install {
    param($Manifest, [string]$Root)
    if (-not $Name) { throw "install needs a name or URL, e.g. .\sideload.ps1 install orcaslicer" }
    $term = $Name[0]

    if ($term -match '^https?://') {
        Invoke-InstallFromUrl -Manifest $Manifest -Root $Root -Url $term
        return
    }

    $index = Get-BucketIndex -CachePath (Join-Path $CacheDir 'buckets.json') -Config $script:Cfg `
                 -MaxAgeHours $bucketCacheHrs -Force:$Refresh -TimeoutSec $TimeoutSec
    $hits  = Find-BucketManifest -Index $index -Term $term -Bucket $Bucket
    if ($hits.Count -eq 0) {
        throw "No Scoop manifest matches '$term'. Add the app to apps.json by hand with the github or html provider."
    }

    $chosen = $hits[0]
    if ($chosen.Name -ne $term -and $hits.Count -gt 1) {
        Write-Head "'$term' is ambiguous"
        foreach ($h in ($hits | Select-Object -First 10)) { Write-Host "    $($h.Name)  [$($h.Bucket)]" }
        Write-Host ''
        if (-not (Confirm-Action "Install '$($chosen.Name)' from $($chosen.Bucket)?")) { return }
    }

    $appId = if ($Id) { $Id } else { $chosen.Name }
    if (Get-ManagedApp -Manifest $Manifest -Id $appId) {
        throw "'$appId' is already managed. Use 'update $appId', or pass -Id to install under a different folder name."
    }

    $entry = [pscustomobject]@{
        id       = $appId
        name     = $chosen.Name
        provider = 'scoop'
        source   = [pscustomobject]@{ bucket = $chosen.Bucket; manifest = $chosen.Name }
    }
    if ($Category) { $entry | Add-Member -NotePropertyName 'category' -NotePropertyValue $Category }

    $up = Resolve-Upstream -Entry $entry
    if (-not $up.Version) { throw "Could not resolve a version for '$($chosen.Name)': $($up.Error)" }

    Write-Head "install $appId $($up.Version)"
    Write-Host "    from  $($up.Origin)"
    Write-Host "    into  $(Join-Path $Root $appId)"
    Write-Host "    url   $($up.Url)" -ForegroundColor DarkGray
    Write-Host ''

    if ($DryRun) { Write-Host '    -DryRun: nothing written.' -ForegroundColor DarkGray; Write-Host ''; return }
    if (-not (Confirm-Action 'Proceed?' -DefaultYes)) { return }

    $result = Invoke-AppInstall -Entry $entry -Upstream $up -Root $Root
    $null = Add-ManagedApp -Manifest $Manifest -Entry $entry
    Save-AppManifest -Manifest $Manifest -Path $ManifestPath

    Write-Host ''
    Write-Host "    installed $appId $($result.Version)" -ForegroundColor Green
    Write-Host "    registered in $ManifestPath" -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-Update {
    param($Manifest, [string]$Root)

    $entries = @($Manifest.apps)
    if ($Name) { $entries = @($entries | Where-Object { $Name -contains $_.id }) }
    if ($entries.Count -eq 0) { throw 'No matching apps.' }

    Write-Head "checking $($entries.Count) app(s) against upstream"

    $rows = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($e in $entries) {
        $i++
        Write-Progress -Activity 'Checking upstream versions' -Status $e.id `
            -PercentComplete ([int](100 * $i / $entries.Count))
        $rows.Add((Get-AppRow -Entry $e -Root $Root -Online))
    }
    Write-Progress -Activity 'Checking upstream versions' -Completed

    $state = @{}
    if (Test-Path -LiteralPath $StatePath) {
        try {
            (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $state[$_.Name] = $_.Value }
        } catch { Write-Warning "Ignoring unreadable state file: $StatePath" }
    }
    $now = (Get-Date).ToUniversalTime()

    $w = ($rows | ForEach-Object { $_.App.Length } | Measure-Object -Maximum).Maximum
    foreach ($r in $rows) {
        Write-Row -Row $r -Width $w
        if ($r.Latest) {
            $prior = Get-Prop $state $r.App
            $changed = if ($prior -and (Get-Prop $prior 'lastSeenVersion') -eq $r.Latest) {
                Get-Prop $prior 'lastChangedUtc' $now.ToString('o')
            } else { $now.ToString('o') }
            $state[$r.App] = [pscustomobject]@{
                lastSeenVersion = $r.Latest
                lastChangedUtc  = $changed
                lastCheckedUtc  = $now.ToString('o')
            }
            if ((New-TimeSpan -Start ([datetime]$changed) -End $now).TotalDays -gt $StaleDays) {
                Write-Host "      ^ upstream unchanged for over $StaleDays days - verify the rule still works" -ForegroundColor DarkYellow
            }
        }
    }

    try { $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8 }
    catch { Write-Warning "Could not write state file: $($_.Exception.Message)" }

    Write-Host ''
    $summary = $rows | Group-Object Status | Sort-Object Name
    Write-Host '  ' -NoNewline
    foreach ($g in $summary) {
        Write-Host ("{0}: {1}   " -f $g.Name, $g.Count) -NoNewline -ForegroundColor $script:StatusColor[$g.Name]
    }
    Write-Host ''

    $actionable = @($rows | Where-Object { $_.Status -eq 'UpdateAvailable' -and $_.Upstream.Url })
    if ($DryRun) {
        Write-Host ''
        Write-Host "  -DryRun: $($actionable.Count) app(s) could be updated. Nothing was modified." -ForegroundColor DarkGray
        Write-Host ''
        return
    }
    if ($actionable.Count -eq 0) {
        Write-Host ''
        Write-Host '  Nothing to update.' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    Write-Host ''
    foreach ($r in $actionable) {
        Write-Host "  $($r.App)  $($r.Installed) -> $($r.Latest)" -ForegroundColor Yellow
        if (-not (Confirm-Action "Update $($r.App)?" -DefaultYes)) {
            Write-Host '    skipped' -ForegroundColor DarkGray
            continue
        }
        $entry = Get-ManagedApp -Manifest $Manifest -Id $r.App
        try {
            $result = Invoke-AppInstall -Entry $entry -Upstream $r.Upstream -Root $Root -IsUpdate
            if ($result.Staged) {
                Write-Host "    staged $($result.Version) - restart PortableSideloader to apply" -ForegroundColor Cyan
                Write-Host "    staged at: $($result.Staged)" -ForegroundColor DarkGray
                continue
            }
            Write-Host "    updated to $($result.Version)" -ForegroundColor Green
            if ($result.Backup) { Write-Host "    backup: $($result.Backup)" -ForegroundColor DarkGray }
            if ($result.RenamedExe) {
                Write-Host "    ! executable renamed ($($result.RenamedExe))" -ForegroundColor Yellow
                Write-Host "      the Platform keys categories by exe name, so re-run 'categorize'" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ''
}

function Invoke-Remove {
    param($Manifest, [string]$Root)
    if (-not $Name) { throw "remove needs an app id, e.g. .\sideload.ps1 remove UserBenchMark" }

    foreach ($n in $Name) {
        $entry = Get-ManagedApp -Manifest $Manifest -Id $n
        if (-not $entry) { Write-Warning "'$n' is not managed."; continue }

        $appDir = Join-Path $Root $n
        $exists = Test-Path -LiteralPath $appDir

        Write-Head "remove $n"
        Write-Host "    folder     $appDir$(if (-not $exists) { '  (already gone)' })"
        Write-Host "    registry   $ManifestPath"
        if ($KeepData) { Write-Host '    keeping    Data\ and any preserved folders' -ForegroundColor DarkGray }
        Write-Host ''

        if ($DryRun) { Write-Host '    -DryRun: nothing deleted.' -ForegroundColor DarkGray; Write-Host ''; continue }
        if (-not (Confirm-Action "Delete $n permanently?")) { Write-Host '    cancelled' -ForegroundColor DarkGray; continue }

        if ($exists) {
            if ($KeepData) {
                $keep = @('Data') + (Get-PreserveList -Entry $entry -Upstream $null)
                Get-ChildItem -LiteralPath $appDir -Force |
                    Where-Object { $keep -notcontains $_.Name } |
                    Remove-Item -Recurse -Force
                Write-Host "    program files deleted, kept: $($keep -join ', ')" -ForegroundColor Green
            } else {
                Remove-Item -LiteralPath $appDir -Recurse -Force
                Write-Host '    folder deleted' -ForegroundColor Green
            }
        }

        $null = Remove-ManagedApp -Manifest $Manifest -Id $n
        Save-AppManifest -Manifest $Manifest -Path $ManifestPath
        Write-Host '    deregistered' -ForegroundColor Green
        Write-Host ''
    }
}

function Invoke-Categorize {
    <#
        Syncs the `category` field in apps.json with the Platform's [AppsRecategorized] section.
        -Import pulls the Platform's current choices into apps.json (read-only, always safe);
        without it, apps.json is pushed to the Platform.
    #>
    param($Manifest, [string]$Root)

    $iniPath = Resolve-MenuIniPath -Root $Root -Override (Get-Setting $script:Cfg 'platformMenuIni')
    $section = $script:MenuSections.Category
    $entries = @($Manifest.apps)
    if ($Name) { $entries = @($entries | Where-Object { $Name -contains $_.id }) }

    if ($Import) {
        Write-Head "import categories from $(Split-Path -Leaf $iniPath)"
        $current = Get-MenuEntries -Path $iniPath -Section $section
        $imported = 0
        foreach ($entry in $entries) {
            # Any of the app's executables may be the one that was categorised; take whichever
            # the Platform actually has an entry for.
            $keys = @(Get-AppMenuKeys -Root $Root -Id $entry.id -Name (Get-Prop $entry 'name' $entry.id))
            $key  = $keys | Where-Object { $current.ContainsKey($_) } | Select-Object -First 1
            if ($key -and $current.ContainsKey($key)) {
                Write-Host ("  {0,-26} {1}" -f $entry.id, $current[$key]) -ForegroundColor Gray
                if (-not $DryRun) {
                    $entry | Add-Member -NotePropertyName 'category' -NotePropertyValue $current[$key] -Force
                }
                $imported++
            } else {
                Write-Host ("  {0,-26} (not categorised in the Platform)" -f $entry.id) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        if ($DryRun) { Write-Host "  -DryRun: $imported would be imported." -ForegroundColor DarkGray }
        else {
            Save-AppManifest -Manifest $Manifest -Path $ManifestPath
            Write-Host "  imported $imported into $ManifestPath" -ForegroundColor Green
        }
        Write-Host ''
        return
    }

    Write-Head "apply categories to $(Split-Path -Leaf $iniPath)"

    $valid = @(Get-Prop $script:Cfg 'categories')
    $wanted = @{}
    foreach ($entry in $entries) {
        $cat = Get-Prop $entry 'category'
        if (-not $cat) { continue }
        if ($valid.Count -gt 0 -and $valid -notcontains $cat) {
            Write-Host "  ! '$cat' on $($entry.id) is not a known category - the Platform may ignore it" -ForegroundColor Yellow
        }
        # Prefer the key the Platform already uses, so applying stays idempotent; otherwise take
        # the best guess. An explicit "exe" in apps.json always wins.
        $existing = Get-MenuEntries -Path $iniPath -Section $section
        $keys = @(Get-AppMenuKeys -Root $Root -Id $entry.id -Name (Get-Prop $entry 'name' $entry.id))
        $pinned = Get-Prop $entry 'exe'
        $key = if ($pinned) { "$($entry.id)\$pinned".ToLowerInvariant() }
               else { ($keys | Where-Object { $existing.ContainsKey($_) } | Select-Object -First 1) }
        if (-not $key) { $key = $keys | Select-Object -First 1 }
        if (-not $key) {
            Write-Host "  ! $($entry.id): no executable found, cannot build a menu key" -ForegroundColor Yellow
            continue
        }
        $wanted[$key] = $cat
    }

    if ($wanted.Count -eq 0) {
        Write-Host '  No apps have a category set. Add "category" to apps.json, pass -Category on install,' -ForegroundColor DarkGray
        Write-Host '  or run: .\sideload.ps1 categorize -Import' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    # The Platform keeps this file in memory and rewrites it on exit, so anything written while
    # it is running would be silently discarded.
    if (-not $DryRun -and (Test-PlatformRunning)) {
        throw 'The PortableApps.com Platform is running. Close it first, or use -DryRun to preview.'
    }

    $changes = Set-MenuEntries -Path $iniPath -Section $section -Entries $wanted -WhatIf:$DryRun
    if ($changes.Count -eq 0) {
        Write-Host '  Already in sync.' -ForegroundColor Green
    } else {
        foreach ($c in $changes) {
            $verb = if ($c.From) { 'change' } else { 'add   ' }
            Write-Host "  $verb $($c.To)" -ForegroundColor $(if ($c.From) { 'Yellow' } else { 'Green' })
        }
        Write-Host ''
        if ($DryRun) { Write-Host "  -DryRun: $($changes.Count) change(s) not written." -ForegroundColor DarkGray }
        else { Write-Host "  wrote $($changes.Count) change(s); backup at $(Split-Path -Leaf $iniPath).sideload-backup" -ForegroundColor Green }
    }
    Write-Host ''
}

function Invoke-Help {
    Write-Head 'portable-sideloader'
    @(
        @('ls',                    'List managed apps and installed versions (offline)'),
        @('search <term>',         'Search the configured buckets for an installable app'),
        @('show <app>',            'Full detail for one app, including upstream version'),
        @('explain <url>',         'Show what would be inferred from a URL, and test it live'),
        @('add <url> -Id <app>',   'Register an already-present folder, without downloading'),
        @('install <name|url>',    'Add an app and install it into the PortableApps folder'),
        @('update [app]',          'Check upstream and apply updates, prompting per app'),
        @('remove <app>',          'Uninstall an app and stop managing it'),
        @('categorize [-Import]',  'Sync apps.json categories with the Platform menu')
    ) | ForEach-Object {
        Write-Host ("    {0}  " -f $_[0].PadRight(22)) -NoNewline -ForegroundColor White
        Write-Host $_[1] -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '    Options: -DryRun -Yes -KeepData -NoBackup -Refresh -Bucket <b> -Id <folder>' -ForegroundColor DarkGray
    Write-Host '             -WatchUrl <page> -VersionPattern <regex> -Preserve a,b -DisplayName <s>' -ForegroundColor DarkGray
    Write-Host '             -PortableAppsRoot <path> -DataDir <path> -TimeoutSec <n> -StaleDays <n>' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    Defaults live in App\config.json; your overrides in Data\config.local.json.' -ForegroundColor DarkGray
    Write-Host '    Registry, state, cache and backups all live under Data\.' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

if ($Command -eq 'help') { Invoke-Help; return }

$manifest = Get-AppManifest -Path $ManifestPath -SeedPath (Join-Path $DataDir 'apps.seed.json')
$rootHint = Get-Prop $manifest 'portableAppsRoot'
if (-not $rootHint) { $rootHint = Get-Setting $script:Cfg 'portableAppsRoot' }
$root = Resolve-PortableAppsRoot -Explicit $PortableAppsRoot -FromManifest $rootHint

switch ($Command) {
    { $_ -in 'ls', 'list' } { Invoke-Ls      -Manifest $manifest -Root $root }
    'search'                { Invoke-Search }
    'show'                  { Invoke-Show    -Manifest $manifest -Root $root }
    'explain'               { Invoke-Explain }
    'add'                   { Invoke-Add     -Manifest $manifest -Root $root }
    'install'               { Invoke-Install -Manifest $manifest -Root $root }
    'update'                { Invoke-Update  -Manifest $manifest -Root $root }
    'remove'                { Invoke-Remove  -Manifest $manifest -Root $root }
    'categorize'            { Invoke-Categorize -Manifest $manifest -Root $root }
}
