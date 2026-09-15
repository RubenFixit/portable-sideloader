# When to Use PortableApps with PortableSideloader Instead of Scoop

[PortableApps](https://portableapps.com/) and [Scoop](https://github.com/ScoopInstaller/Scoop) both make Windows software easier to manage without relying on traditional system-wide installers, but they optimize for different outcomes.

Scoop is a command-line installer for Windows. It installs and maintains applications in a user's Windows context, integrates them with the shell, resolves dependencies, and supports repeatable setup through manifests and buckets.

PortableApps treats the application collection as the portable unit. Applications, launchers, and compatible user data can remain together on a local drive, removable drive, or synchronized directory. [PortableSideloader](README.md) extends that model to portable applications that are not maintained by the [official PortableApps catalog](https://portableapps.com/apps).

The choice is mostly about what needs to survive a move:

- Use Scoop when the goal is to install and maintain software for the current Windows user.
- Use PortableApps with PortableSideloader when the application collection and its accumulated data need to move or synchronize together.
- Use both when some applications should travel while others only need clean integration with each system.

## The two operating models

### PortableApps with PortableSideloader

The [PortableApps.com Platform](https://portableapps.com/) provides a menu, a common directory layout, portable launchers, backup support, and conventions for keeping application data with the application. It is designed for local, portable/USB, and cloud-drive use.

Applications packaged in the [PortableApps.com Format](https://portableapps.com/development/portableapps.com_format) separate program files from user data. The standard layout places settings and profiles in a `Data\` directory so they can remain intact when the application is updated or moved. The format also defines metadata, icons, launchers, installer behavior, and rules for handling changes made to the host computer.

PortableSideloader extends this collection model to applications distributed as portable archives, standalone executables, GitHub releases, or other vendor downloads. It records update sources in `Data\apps.json`, compares installed and upstream versions, verifies downloads when hashes are available, preserves configured data paths, and replaces application payloads in the PortableApps directory.

PortableSideloader does not make an application portable by itself. It can preserve known files and directories, but an application may still write to the registry, user profile, credential store, services, drivers, or other system locations. A full PortableApps launcher can handle more application-specific cleanup and path adjustment than a general sideloader.

### Scoop

[Scoop describes itself](https://github.com/ScoopInstaller/Scoop) as a command-line installer for Windows. By default, it installs applications for the current user under `%USERPROFILE%\scoop`, avoids many UAC prompts and installer side effects, resolves dependencies, and exposes commands through shims instead of adding every application directory directly to PATH.

Scoop applications are described by JSON manifests. A manifest can define downloads, hashes, architecture-specific packages, dependencies, shortcuts, commands to expose through shims, update checks, and persistent data. [Buckets](https://github.com/ScoopInstaller/Scoop/wiki/Buckets) are Git repositories containing collections of those manifests, and users can add official, community, or private buckets.

Scoop's [`persist`](https://github.com/ScoopInstaller/Scoop/wiki/Persistent-data) feature keeps selected files and directories across updates by linking them to a stable per-app data directory. This preserves declared application data during package upgrades, although it does not guarantee that every application keeps all of its state inside the Scoop layout.

Scoop can use a custom root and its files can be copied or synchronized, but that is not the same experience as a PortableApps collection. Its [folder layout](https://github.com/ScoopInstaller/Scoop/wiki/Scoop-Folder-Layout) includes applications, buckets, persistence data, cache, and shims under the Scoop root, while configuration normally lives under the user's profile. PATH configuration, environment variables, architecture, credentials, and application-specific behavior can still require setup on each computer.

## Comparison

| Criterion | PortableApps + PortableSideloader | Scoop |
|---|---|---|
| Primary goal | Maintain a movable application collection | Install and maintain Windows software for a user |
| Normal scope | A PortableApps directory | A Windows user profile |
| Default location | `PortableApps\PortableApps` within the Platform directory | `%USERPROFILE%\scoop` |
| Administrative access | Usually unnecessary, although individual apps may still require elevation | Usually unnecessary for user installs; global installs require elevation |
| Application discovery | Official PortableApps catalog plus sideloader sources and buckets | Official, community, and private Scoop buckets |
| Updates | PortableApps updater for official packages; PortableSideloader for managed custom apps | Manifest-driven installs and updates through Scoop |
| Application data | Travels naturally when contained by a PAF launcher or configured preservation rules | Declared `persist` paths survive upgrades inside the Scoop layout |
| Shell integration | Optional direct PATH entries that may need refreshing after a move | Shims and manifest-defined environment changes |
| Menu integration | Native PortableApps menu integration | Shortcuts can be created, but there is no PortableApps-style collection menu |
| Moving to another computer | Strong when apps and data are genuinely portable | Possible, but user configuration and shell integration may need repair |
| USB use | A primary use case | Possible with deliberate setup, but not the default model |
| Cloud synchronization | Natural for a closed application collection; apps should be closed before syncing | Possible with a fixed layout; avoid concurrent updates and account for profile-level configuration |
| Reproducible setup | Reproduces a lived-in collection, including compatible settings and profiles | Reproduces a clean application set well through manifests, buckets, export/import, and scripts |
| Best fit | Applications and data that should travel together | Applications that should be installed cleanly for each Windows user |

Both approaches are reproducible, but they reproduce different things. PortableApps is good at carrying an environment with its history: preferences, profiles, extensions, templates, and other application data. Scoop is good at rebuilding a declared set of applications without carrying previous use and configuration unless that data is deliberately preserved or restored.

## Use PortableApps with PortableSideloader when

### The collection itself needs to move

PortableApps is the stronger choice when a directory should be copied, carried on a removable drive, or synchronized to another computer and remain useful with little additional setup. The PortableApps menu and launchers move with the applications, and compatible application data can move with them.

Typical examples include:

- keeping the same GUI applications and settings on multiple computers;
- carrying a troubleshooting or field-service toolkit on removable storage;
- synchronizing a personal application collection through OneDrive, Nextcloud, or another file-sync service;
- using applications on a computer where traditional installation requires administrator approval;
- preserving configured profiles, extensions, templates, or other working data with the application.

### PortableApps already contains the working environment

Replacing an established PortableApps collection with another package manager may provide little benefit if the applications and their data are already arranged correctly. PortableSideloader adds update automation to that existing layout without requiring the collection to be rebuilt around a different tool.

### An application is portable but missing from the official catalog

The official PortableApps updater maintains applications in its own catalog. PortableSideloader is useful when a vendor provides a suitable portable archive or executable, but no official PAF package exists. It supplies the missing version-check, download, preservation, and replacement workflow.

### Continuing from the same application state matters

PortableApps is especially useful when reproducing previous use is a benefit rather than a liability. A synchronized collection can carry the actual browser profile, editor configuration, templates, media library state, or other compatible data instead of rebuilding those settings on every computer.

## Use Scoop when

### Software should be installed for the current user

Scoop provides a concise workflow for installing, updating, and removing software without most traditional installer prompts. It is a good default when the application only needs to work for the current user and there is no requirement to carry the installed directory to another computer.

### Shell integration matters more than collection portability

Scoop's shims make command-line programs available without adding each application's installation directory to PATH. Manifests can also define aliases, environment variables, dependencies, and additional PATH entries. This is usually cleaner than maintaining direct PATH entries into a movable PortableApps directory.

Git is a good example. Portable Git can be useful when it must travel with a toolkit, but a Scoop-managed Git installation is generally more convenient when Git is primarily used from PowerShell, Command Prompt, terminals, editors, and build tools on that computer.

### A clean, repeatable setup is preferred

Scoop is well suited to rebuilding an application set from manifests, buckets, scripts, or its [`export` and `import` commands](https://github.com/ScoopInstaller/Scoop/wiki/Commands). This favors a known clean state. Application data can be restored separately or retained through manifest `persist` rules when appropriate.

### The application already has a well-maintained Scoop manifest

Using an existing Scoop manifest avoids maintaining a private version check, download URL, hash, and extraction rule. Scoop's larger manifest ecosystem is a practical advantage when collection portability is not required.

## Use both when the split is useful

PortableApps and Scoop can coexist on the same computer. A practical division is:

- PortableApps with PortableSideloader for GUI applications, portable utilities, and data that should travel with the collection.
- Scoop for command-line tools and other applications that benefit from shims, dependencies, and user-context integration.

This is not a requirement to divide applications by interface. A GUI application may fit Scoop better, and a command-line utility may belong in a portable field toolkit. The deciding factor is whether the application should be integrated into each Windows user environment or carried as part of the collection.

## Cases where neither approach guarantees portability

Some software depends on drivers, services, shell extensions, machine certificates, hardware-specific configuration, licensed activation, or files stored outside its managed directory. Neither extracting such software into PortableApps nor installing it through Scoop removes those dependencies.

Use a normal installer or the vendor's supported deployment method when the application requires deep Windows integration. PortableSideloader should only manage an application after its portable behavior and data locations are understood.

External integration also reduces portability. Direct PATH entries, file associations, shortcuts, protocol handlers, and credentials belong to the Windows user or machine rather than the collection. PortableSideloader can add and remove PATH entries, but they may need to be refreshed when the collection moves to another drive letter or directory.

## Maintaining an app that is missing from PortableApps

There are four practical options, typically ordered from least to most effort:

| Option | Typical effort | Best fit |
|---|---|---|
| Maintain a private entry in `Data\apps.json` | Lowest | A personal app, licensed edition, experimental rule, or immediate local need |
| Contribute a Scoop-compatible manifest to the PortableSideloader bucket | Low | An app useful to other PortableSideloader users or multiple installations |
| Contribute a manifest to a Scoop bucket | Medium | An app that fits Scoop's installation model and is useful to its broader community |
| Create and contribute a PortableApps PAF package | Highest | A genuinely portable and legally distributable app worth full PortableApps integration |

A local `apps.json` entry is the fastest option because there is no contribution process. Moving the entry into [PortableSideloader's included bucket](bucket/) makes it searchable and reusable while retaining PortableSideloader-specific providers and preservation behavior.

Contributing to Scoop makes sense when the application is broadly useful outside PortableApps. Scoop already has conventions for [`checkver`, `autoupdate`, hashes, architecture, dependencies, shims, and persistence](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests).

Creating a proper PAF package provides the deepest PortableApps integration, but it is substantially more work. A package normally needs launcher configuration, `AppInfo` metadata, icons, installer configuration, default data, portability testing, release packaging, and continued compatibility work. PortableApps.com provides the [format, launcher, installer, template, and development resources](https://portableapps.com/development) needed for that process.

These options can be progressive. An application can begin as a private entry, move into the PortableSideloader bucket after it is proven, and later be contributed to Scoop or packaged for PortableApps when the broader maintenance effort is justified.

## Why PortableSideloader exists

PortableSideloader was built for an existing PortableApps collection that already contained manually sideloaded applications. The missing capability was not application installation in general; it was repeatable updates for those applications without abandoning the PortableApps layout.

It therefore focuses on a narrow gap:

1. Keep applications inside the PortableApps collection and visible through its menu.
2. Retain the ability to move or synchronize the collection.
3. Add repeatable update rules for applications outside the official catalog.
4. Preserve application data where the software supports it.
5. Avoid requiring every personal or niche application to become a full PAF package.

PortableSideloader maintains a local app registry, resolves upstream versions, downloads and verifies payloads, preserves configured paths, and replaces application directories under the PortableApps root. It adds package-management behavior to a portable collection without claiming to replace Scoop as a general Windows installer.

## What about synchronizing Scoop?

A synchronized Scoop installation is possible, especially when each computer uses the same root path, drive letter, architecture, and user configuration. The Scoop root can include `apps`, `buckets`, `persist`, and `shims`; the download cache can either be synchronized or recreated.

Each Windows user still needs the Scoop root, shim directory, and profile-level configuration set correctly. Synchronization also needs to avoid applications or Scoop updating on two computers at once. This can be manageable for a controlled personal setup, but it requires more host setup than using a PortableApps collection as the transferable unit.

The existence of that option does not make PortableSideloader unnecessary. PortableSideloader is useful when PortableApps is already the collection being maintained and the goal is to automate its missing update path. A Scoop synchronization tool would solve a related but different problem.

## Conclusion

PortableApps with PortableSideloader is the better fit when applications and compatible user data should travel together as a working collection. Scoop is the better fit when applications should be installed and integrated cleanly for each Windows user, especially when shims, dependencies, and repeatable clean setup are valuable.

Neither is universally better. The deciding question is whether the durable unit should be the application collection or the Windows user environment.

## Further reading

- [PortableApps.com Platform](https://portableapps.com/)
- [PortableApps.com Platform support and backup behavior](https://portableapps.com/support/platform)
- [What is a portable app?](https://portableapps.com/about/what_is_a_portable_app)
- [PortableApps.com development resources](https://portableapps.com/development)
- [PortableApps.com Format specification](https://portableapps.com/development/portableapps.com_format)
- [PortableApps.com Format directory layout](https://portableapps.com/manuals/PortableApps.comLauncher/ref/paf/layout.html)
- [Scoop project overview](https://github.com/ScoopInstaller/Scoop)
- [Scoop app manifests](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests)
- [Scoop buckets](https://github.com/ScoopInstaller/Scoop/wiki/Buckets)
- [Scoop persistent data](https://github.com/ScoopInstaller/Scoop/wiki/Persistent-data)
- [Scoop folder layout](https://github.com/ScoopInstaller/Scoop/wiki/Scoop-Folder-Layout)
- [Scoop commands, including export and import](https://github.com/ScoopInstaller/Scoop/wiki/Commands)
