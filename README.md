# portable-sideloader

Package and auto-update manually added apps in your PortableApps.com menu — the ones the official
updater skips.

The PortableApps.com Platform checks for updates by reading `PackageVersion` from each app's
`appinfo.ini` and comparing it against a central database at a hardcoded `portableapps.com/updater/`
URL, keyed by `AppID`. There is no supported way to add your own entries, so apps you dropped into
the directory yourself are silently skipped forever.

This tool maintains those apps in parallel, without touching the Platform.

## Usage

One entry point, eleven commands.

```powershell
cd App
.\sideload.ps1 ls                    # managed apps and installed versions (offline)
.\sideload.ps1 search slicer         # find an installable app in the configured buckets
.\sideload.ps1 show OrcaSlicer       # full detail, including the upstream version
.\sideload.ps1 explain <url>         # show what a URL infers to, and test it live
.\sideload.ps1 add <url> -Id MyApp   # register a folder you already have, no download
.\sideload.ps1 install orcaslicer    # install by bucket name...
.\sideload.ps1 install <url>         # ...or straight from a download URL
.\sideload.ps1 update                # check everything, prompt per app
.\sideload.ps1 remove UserBenchMark -KeepData
.\sideload.ps1 categorize -Import    # pull Platform categories into apps.json
.\sideload.ps1 categorize            # push apps.json categories to the Platform
.\sideload.ps1 hold MobaXterm -Reason "licensed edition"
.\sideload.ps1 restore OrcaSlicer -List
```

Useful flags: `-DryRun`, `-Yes`, `-KeepData`, `-NoBackup`, `-Refresh`, `-Bucket`, `-Id`,
`-DisplayName`, `-WatchUrl`, `-VersionPattern`, `-Preserve`, `-Category`, `-PortableAppsRoot`,
`-DataDir`, `-ConfigPath`, `-LocalConfigPath`.

`update -DryRun` is the safe way to see where everything stands.

## Adding a source without touching the code

Point it at any download URL and it works out how to track updates:

```
> .\sideload.ps1 explain https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v2.4.2/OrcaSlicer_Windows_V2.4.2_x64_portable.zip

    rule       github-release-asset
    provider   github
    version    2.4.2  (matched 'semver3')
    source
      repo              OrcaSlicer/OrcaSlicer
      assetPattern      ^OrcaSlicer_Windows_V\d+\.\d+\.\d+_x64_portable\.zip$

    live check:
      resolves to 2.4.2
```

It finds the version inside the filename, then rebuilds the filename as a regex with everything
except the version escaped. That regex matches other releases of the same file and nothing else —
much tighter than hunting for a bare `\d+\.\d+\.\d+` across a whole page.

For a non-API host, the same derivation produces a watch page and a URL template:

```
> .\sideload.ps1 explain https://files.openscad.org/OpenSCAD-2021.01-x86-64.zip

    rule       generic-url
    provider   url
    version    2021.01  (matched 'calver')
    source
      watchUrl          https://files.openscad.org/
      versionPattern    OpenSCAD-(?<version>20\d{2}[.-]\d{2}(?:[.-]\d+)?)-x86-64\.zip
      urlTemplate       https://files.openscad.org/OpenSCAD-{version}-x86-64.zip
```

When a URL carries no version at all, it says so rather than guessing:

```
    ! No version found in 'UsbTreeView_x64.zip'. Updates cannot be tracked from this URL alone -
      pass -WatchUrl and -VersionPattern, or edit the entry in apps.json.
```

`explain` never writes anything. `install <url>` and `add <url>` run the same inference and show it
before asking to proceed.

## Layout

Code and data are separated so the tool can eventually update itself without destroying your
setup — the same `App\` / `Data\` split the Platform uses, enforced by the same `preserve`
mechanism this tool applies to every other app.

```
portable-sideloader\
  PortableSideloader.exe    launcher stub (tools\build.ps1)
  tools\                    build and release scripts
  App\                      replaced wholesale on update
    sideload.ps1
    config.json             shipped defaults
    VERSION                 what `update` compares against for itself
    src\*.ps1
    Launcher\Launcher.cs
  Data\                     yours, never touched
    apps.json               the registry (seeded on first run)
    apps.seed.json          starting registry, registers this tool with itself
    config.local.json       your overrides
    state.json  cache\  backups\  update\
```

Run `App\sideload.ps1` from anywhere; it finds `Data\` as a sibling. `-DataDir` overrides that,
which is also how you point two checkouts at one registry.

## The launcher stub

```powershell
.\tools\build.ps1
```

Compiles `PortableSideloader.exe` (~15 KB) using the `csc.exe` that ships with Windows — no SDK, no
package manager, no admin. Drop the folder into your PortableApps directory and the Platform picks
up the exe; right-click it and tick **Start Automatically** for prompt-on-launch.

It exists for three reasons, none of them cosmetic:

1. **The Platform launches executables, never `.ps1` files.** You need a stub regardless of how the
   code is organised, which is why keeping everything behind one script costs nothing.
2. **It applies a staged self-update before any script loads.** A running process can't overwrite
   its own files, so updates stage into `Data\update\` and get swapped in here — the one moment
   nothing holds them open. The stub can't overwrite *itself* either, so it renames itself to
   `.old` and drops the new one in; that takes effect on the next launch, and the `.old` is cleaned
   up then too.
3. **It starts PowerShell with `-ExecutionPolicy Bypass`**, so a `.ps1` carrying Mark-of-the-Web
   from a GitHub download can't be blocked.

With no arguments — how the Platform starts it — it runs `update`, then waits for a keypress so the
summary is readable. With arguments it passes them straight through and doesn't pause, so
`PortableSideloader.exe ls` behaves like the script. Exit codes propagate either way.

## Configuration

`App\config.json` holds the shipped defaults; `Data\config.local.json` layers your overrides on
top. Adding a host, a version shape, a bucket, or changing a path should never mean editing a
`.ps1` — or losing your edits when the code updates.

Merge rules: **scalars replace**, **nested objects merge key by key**, and **arrays put your
entries first**, dropping shipped entries that share a `name`. So a local host rule wins, a local
bucket named `Extras` replaces the shipped one, and anything you don't mention keeps the shipped
default *and keeps receiving updates to it*. See `Data\config.local.example.json`.

- **`settings`** — paths, timeouts, `staleDays`, user agent, and the 7-Zip search list (supports
  `%ENVVAR%` and a `<root>` placeholder for the PortableApps directory). Command-line parameters
  override these.

  `autoUpdateSelf` defaults to `true`. When the launcher starts an `update` command, it checks this
  setting first, stages a newer portable-sideloader release if available, relaunches, and only then
  checks the rest of the registry. `update -DryRun` reports the self-update without staging it.
- **`buckets`** — name, `manifestUrl` template, `indexRepo`, optional `branch`, and a `rank` used to break search
  ties. Add your own bucket here and `search`/`install` pick it up.

The shipped `RubenFixit` bucket points at this repository's `bucket\` directory. Put manifests
there for apps that are not in Scoop yet; they become available to `search` and `install` after
the bucket index refreshes. A clean manifest can later be proposed to Scoop Main or Extras without
changing the sideloader entry that records the installed folder and preserved data.

The recommended flow is bucket-first: add the manifest, install by bucket name, and let the bucket
be the update source. The sideloader does not rewrite bucket manifests during `update`; it only
reads them. This keeps app updates separate from repository writes and credentials. GitHub Actions
runs `tools\Update-Bucket.ps1 -Apply` daily and can also be started manually from the Actions tab,
then commits changed manifests. Once that commit is visible, the next sideloader update sees it.

Bucket manifests can opt into the shared updater with an `x-portable-sideloader` block containing
the same `provider` and `source` shape used by `apps.json`. Preview changes with
`tools\Update-Bucket.ps1`; add `-Apply` to write updated `version`, `url`, and `hash` values. GitHub
asset digests are used when published; otherwise the updater downloads the artifact to calculate
the SHA-256 before writing it.
- **`versionPatterns`** — the ordered regex library used to spot a version. First hit wins, so put
  your own at the top. Use `(?: )` for grouping; numbered groups would break the derived regexes.
- **`hosts`** — ordered rules matched against a download URL to pick a provider. Named captures are
  available as `${name}`, alongside derived tokens `${assetRegex}`, `${filenameRegex}`,
  `${urlTemplate}` and `${watchUrl}`.

`Data\apps.json` is the per-app registry — yours, untracked, seeded on first run from
`apps.seed.json`. See `Data\apps.example.json` for the shape and the optional `exe` / `preserve` /
`category` / `hold` fields.

## Requirements

Windows PowerShell 5.1 or PowerShell 7+. No modules, no admin.

A deliberate choice, not an accident: at 1,888 lines this stays a script rather than a compiled
binary because there's no performance case for the rewrite — a full 17-app upstream check runs in
**1.7 seconds**. The trade is real, though. PowerShell's habit of unrolling single-element arrays
on `return` caused three separate bugs during development, one of which would have silently wiped
user data rather than crashing; a typed language turns those into compile errors. If this ever
gets distributed to other people, Mark-of-the-Web and ExecutionPolicy friction on downloaded
`.ps1` files becomes the stronger argument for shipping a binary instead.

## Providers

| Provider | Source | Notes |
|---|---|---|
| `scoop` | A bucket manifest's raw URL | Reads `version`, `url`, `hash`, `persist`. Community-maintained `checkver`/`autoupdate` keeps it current. No Scoop installation required — it's just a public JSON file. |
| `github` | `api.github.com/repos/<owner>/<repo>/releases/latest` | `assetPattern` picks the Windows asset; `prerelease: true` follows pre-releases. |
| `url` | A watch page + `versionPattern`, and a `urlTemplate` | Takes the **highest** version on the page, not the first — vendor pages routinely list the newest release below a banner or changelog. |
| `todo` | — | No rule written yet; reported so it stays visible. |

Harvesting Scoop's manifests rather than installing Scoop is intentional: it borrows the
community's version tracking for most of the list while keeping this folder self-contained and
copyable to a USB stick.

## Holding an app back

Some apps must never be updated automatically, because upstream tracks a *different product* than
the one you run. The Scoop manifest for MobaXterm points at `MobaXterm_Portable_v26.4.zip`, license
`Freeware` — the Home edition. Accepting that update on a licensed Pro install would quietly
replace it.

```powershell
.\sideload.ps1 hold MobaXterm_Pro_Portable -Reason "licensed Pro edition; upstream tracks Home"
```

A held app is still checked and reported — you want to know a release exists — but never applied:

```
MobaXterm_Pro_Portable  23.2*  ->  26.4  UpdateAvailable  HELD (licensed Pro edition; upstream tracks Home)

  1 held app(s) have updates and will be skipped: MobaXterm_Pro_Portable
  Use -Force to update them anyway, or 'unhold <app>' to stop holding.
```

`hold` with no `-Reason` sets `"hold": true`; with one it stores the string and prints it every
time, so the reason survives longer than your memory of it.

## Rolling back

Every update writes the whole app folder to `Data\backups\<id>\<timestamp>\` first, unless
`-NoBackup`.

```powershell
.\sideload.ps1 restore OrcaSlicer -List      # what's available
.\sideload.ps1 restore OrcaSlicer            # newest
.\sideload.ps1 restore OrcaSlicer 20260817-212338
```

The folder is replaced wholesale, user data included — that's what a rollback means. The current
state is backed up first, so the restore is itself reversible. Restoring the tool over itself is
refused, since it can't overwrite files it's running from.

## It manages itself

`Data\apps.json` is seeded on first run from `apps.seed.json`, which contains one entry: this tool.
So `update` tracks portable-sideloader's own releases through the same `github` provider as
everything else, and there is nothing to set up.

The entry carries `"self": true`, which changes two things:

- **The installed version comes from `App\VERSION`**, not from sniffing a binary.
- **Updates are staged, not swapped.** This process holds `App\*.ps1` open and the launcher holds
  the `.exe`, so a normal in-place swap would fail or corrupt the install. Instead the payload
  lands in `Data\update\`, and the launcher applies it on next start — before anything is loaded.

```
PortableSideloader  0.0.1 -> 0.1.0  UpdateAvailable
    staged 0.1.0 - restart PortableSideloader to apply
```

On the next launch the stub swaps `App\`, refreshes the root files, renames itself aside for the
new binary, and leaves `Data\` alone. Delete the entry from `apps.json` if you would rather update
it by hand.

## Menu categories (and why PAF wrapping isn't worth it)

A sideloaded app shows up under **Other** after a menu refresh, and recategorising it is a one-time
click. The Platform stores that choice in its own config, not in the app folder:

```ini
; PortableApps.com\Data\PortableAppsMenu.ini
[AppsRecategorized]
orcaslicer\orca-slicer.exe=Development
```

Two consequences:

- **Categories survive updates.** They live outside the app folder, so a payload swap can't touch
  them. No PAF wrapping needed to keep them.
- **The key includes the executable name.** An update that *renames* the exe silently drops the
  category — along with anything in `[AppsRenamed]` and `[AppsHidden]`. `update` detects a rename
  and tells you to re-run `categorize`.

PAF wrapping would make this worse, not better: it changes the launched executable to
`<Folder>\<AppID>.exe`, which invalidates every existing key. You'd have to redo categorisation you
already did, in exchange for a category field you can set from `apps.json` anyway.

`categorize -Import` reads the Platform's current choices into `apps.json` (read-only, always
safe). `categorize` pushes them back. `-Category` on `install`/`add` sets one up front. That makes
your categorisation reproducible if you ever rebuild the stick.

The Platform holds `PortableAppsMenu.ini` in memory and rewrites it on exit, so `categorize`
refuses to write while it's running. `-DryRun` always works. A `.sideload-backup` is written
alongside the file before any change.

Note the Platform spells these categories with "and", not "&" — `Music and Video`, not
`Music & Video` as in the PAF spec. The accepted list is in `config.json`.

## How the installed version is determined

1. `.sideload.json` — written into the app folder on every install and update. Authoritative.
2. `App\AppInfo\appinfo.ini` → `DisplayVersion` / `PackageVersion`, if the app is PAF-format.
3. The `ProductVersion` of the app's main executable — a **heuristic**, marked with `*` in output.
4. Otherwise `NoBaseline`.

Tier 1 exists because several sideloaded apps ship executables with no version resource at all
(OpenSCAD and OrcaSlicer among them), leaving nothing to compare against. It is deliberately *not*
`appinfo.ini`: writing that would make the Platform treat a flat folder as a PAF app and expect a
layout it doesn't have.

## What `update` actually does

1. Resolve the upstream version, download URL, and SHA256.
2. Download to `cache/`, then **verify the hash** — a mismatch discards the file and aborts.
3. Extract to `cache/staging/` (`Expand-Archive` for zips, 7-Zip otherwise).
4. Copy the whole app folder to `backups/<id>/<timestamp>/` unless `-NoBackup`.
5. Move the preserved paths aside, delete the old payload, move the new one in, restore them.
6. Write `.sideload.json`.

Preserved paths come from the Scoop manifest's `persist` field, or from a `preserve` array on the
app's entry in `apps.json`. That's how VS Code's `data` and Sublime's `Data` survive an update.

If no hash is published for a source, you get a warning rather than silent trust.

## Staleness warnings

Silent failure is this design's main weakness: a broken regex looks exactly like "no update
available." Any app whose upstream version hasn't moved in over `staleDays` (default 180) is called
out so you go check the rule rather than assuming all is well. Needs a few runs of history in
`state.json` before it can fire.

## Roadmap

- [x] `scoop` / `github` / `url` providers
- [x] `ls` / `search` / `show` / `explain` / `add` / `install` / `update` / `remove`
- [x] Download, hash verify, backup, atomic swap with data preservation
- [x] Config-driven hosts, version patterns, buckets and paths
- [x] Regex inference from a download URL
- [x] Menu category sync, both directions
- [x] `App\` / `Data\` split with layered config
- [x] Launcher stub + staged-update swap, for **Start Automatically**
- [x] Self-update — the tool is registered in its own registry and stages its own releases
- [x] `hold` for apps upstream tracks a different edition of
- [x] `restore` for rolling back from backups
- [ ] Custom rules for the remaining `todo` apps (MiniTool Partition Wizard, PortableRegistrator)
- [ ] Per-app version normalisers, for sources like Sublime that report `4-4200` vs `4200`
- [ ] `[AppsRenamed]` / `[AppsHidden]` sync, same mechanism as categories
- ~~PAF wrapping~~ — dropped; see the categories section for why it would cost more than it gives

### On the launcher stub

The Platform launches an *executable*, never a `.ps1`, so autostart needs a small stub regardless
of how the code is organised. Keeping everything behind one script costs nothing here.

### 7-Zip

7-Zip is needed for `.7z` payloads and installer-exe extraction. Search locations are configurable
in `settings.sevenZipPaths`; the default list covers `PATH`, `Program Files`, and
`<root>\7-ZipPortable` — add that last one to your stick if you want extraction to work on any
machine.

Set `GITHUB_TOKEN` to raise the GitHub API rate limit (60/hr unauthenticated). Only the `github`
provider and bucket indexing need it; manifest reads are raw files and aren't rate limited.

## License

MIT




