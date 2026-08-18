# Why I Chose PortableApps and PortableSideloader Instead of Scoop

## Executive summary

When I started looking at Scoop, I realized that it solves a different problem than the one I was actually having. Scoop is probably the cleaner way to install and maintain software for a Windows user. But I already had a PortableApps collection, I was already manually adding apps that were not in the official catalog, and I wanted that collection to remain movable and usable on another computer.

- Scoop makes Windows software easy to install, update, remove, and add to the shell for the current user.
- PortableApps makes an application collection, its launchers, and, when the application is packaged correctly, its data easy to move between Windows systems.
- PortableSideloader fills the gap when PortableApps has the deployment model I want, but the application is not in the official catalog.

The missing piece was not another installer. It was an updater for the apps I had already chosen to keep portable. The PortableApps Platform provides the collection and portability model I wanted, but its official updater does not maintain arbitrary apps added outside the catalog. PortableSideloader adds manifest-driven updates to that existing collection without requiring every app to become a full PAF package first.

Scoop is still useful. Choosing PortableApps does not prevent me from using Scoop on the same systems for user-context command-line installs.

## What I was actually trying to solve

The question I was trying to answer was not whether Scoop is a good package manager. It is. The question was whether I should replace my existing PortableApps collection with Scoop, or add the missing update capability to the collection I was already using.

What I wanted was more specific than simply avoiding an installer or installing without elevation:

> Keep a useful set of applications and their settings together, usable on another supported Windows system with minimal reconfiguration, while avoiding administrative installation requirements where possible—and continue receiving updates for applications that the PortableApps Platform does not track.

That is the reason PortableSideloader made more sense for me than replacing the collection with Scoop.

## What each system optimizes for

### PortableApps and PortableSideloader

PortableApps gives me a menu, a common directory layout, portable launchers, and a convention for keeping application data with the application. The platform is intended for local, USB, and cloud-drive use, including a synced application collection. PortableApps-format packages place personal data in a predictable `Data\` directory, which makes backup and movement easier.

PortableSideloader extends that model to applications that are available as portable archives or vendor downloads but are not in the official catalog. It keeps the application under the PortableApps root, records the source and update rules in `Data\apps.json`, preserves selected data paths, and updates the application in place.

The important part for me is that the collection is the thing that moves. I am not just installing the same applications again on another computer. I am moving the applications, their launchers, and, where supported, their working data together.

## Ways to maintain an app that is missing from PortableApps

PortableSideloader's `apps.json` does not have to be the permanent home for every missing application. There are four reasonable options, and they go from a small personal change to a full upstream packaging project:

| Option | Effort | What it means | Best fit |
|---|---|---|---|
| Maintain a private manifest in the installed PortableSideloader | Lowest | Add the app to my local `Data\apps.json` and maintain it only for my own collection | A personal app, licensed edition, experimental rule, or anything I need working immediately |
| Contribute a Scoop-compatible manifest to the PortableSideloader bucket | Low | Add the app to this repository's private bucket so it can be searched for and installed by other PortableSideloader users | An app that is useful to this collection and can be described with the sideloader manifest format |
| Contribute a manifest to the official Scoop buckets | Medium | Follow Scoop's manifest conventions, submit the change upstream, and maintain it for the broader Scoop community | An app that fits Scoop's user-context installation model and has a generally useful distribution source |
| Contribute a PortableApps PAF package | Highest | Build the launcher, metadata, installer, default data, and package required for official PortableApps distribution | An app that is genuinely portable, legally distributable, broadly useful, and worth maintaining as a full PAF package |

The first option is the fastest because there is no contribution process at all. I can add an entry to the installed copy of `apps.json`, test it against my own directory layout, and change it whenever I need to. The downside is that the manifest is tied to my collection.

The second option is the natural next step for this project. A Scoop-compatible manifest in the PortableSideloader bucket can be searched for and installed through PortableSideloader, while still supporting the custom providers, preservation rules, and PortableApps-oriented behavior that this repository needs. It is still much lighter than creating a PAF package, but the manifest becomes shared maintenance instead of a private workaround.

The third option makes sense when the application is useful beyond PortableApps. The official Scoop buckets provide broader reach and established conventions for version checks, autoupdates, hashes, dependencies, persistence, and version cleanup. The tradeoff is that the manifest has to fit Scoop's expectations, and Scoop's package-management model may not cover the PortableApps-specific details I care about.

Contributing an app to PortableApps.com has the greatest potential reach inside the PortableApps ecosystem, but it is also the most work. PortableApps.com provides the format specification, launcher, installer, development resources, and a development forum for creating and testing packages. Official inclusion gives the application a standard package identity, menu integration, update metadata, and a way for other users to discover it.

A proper PAF package is considerably more work than a sideloader entry. It needs launcher configuration for application-specific paths and host changes, `AppInfo` metadata and icons, installer configuration, default data, portability testing, release packaging, and continued compatibility work as the application changes. A sideloader entry can often describe the upstream version, download, hash, executable, and preserved paths in a few manifest fields. For a personal side project, that difference matters. A PAF package is a real packaging project, not just a JSON file.

For me, the practical progression is to start with a private manifest, move useful entries into the PortableSideloader bucket, contribute generally useful applications to Scoop when they fit that model, and only create a PAF package when the application and the extra maintenance are worth the broader PortableApps integration. These paths can also be sequential. A local entry can help me learn the app's data and launcher requirements before I decide whether it is ready for one of the upstream projects.

### Scoop

Scoop is a command-line Windows installer and package manager. It generally installs per-user without administrator access, extracts applications into a Scoop root, creates shims, manages versions, and updates applications from manifests. Its default per-user layout is under `%USERPROFILE%\scoop`, with apps, buckets, cache, persisted data, and shims stored in separate subdirectories.

Scoop can use a custom root and can therefore be placed somewhere other than the default user profile. That makes it possible to copy or synchronize parts of a Scoop installation, but it isn't intended to be moved between computers. Shims, environment variables, configuration, cached state, architecture, credentials, and machine-specific application behavior may still need repair or reconfiguration.

The important difference is that Scoop is installing and managing software in the user's Windows context, including the user's shell environment.

## Comparison

| Criterion | PortableApps + PortableSideloader | Scoop |
|---|---|---|
| Primary goal | Move and reuse an app collection | Install and maintain software in a user's Windows context |
| Install location | PortableApps root | Scoop root, normally under the user profile |
| Administrative access | Usually unnecessary for the app files; individual apps may still require elevation | User installs usually avoid elevation; global installs require it |
| Update experience | PortableSideloader checks manifests/providers and swaps app folders while preserving configured data | Mature manifest-driven update flow with buckets, shims, dependencies, and version cleanup |
| App availability | Official PortableApps catalog plus custom sideloaded sources | Very broad Scoop bucket ecosystem, including community buckets |
| Moving to another PC | Strong when the app is genuinely portable and data is inside the collection | Possible with deliberate configuration, but not seamless by default |
| USB/offline use | Strong, subject to drive speed and application behavior | Possible if the Scoop root is moved, but shims and configuration reduce the convenience |
| Cloud synchronization | Natural fit for a collection, though apps must be closed before syncing | Possible, but cache, shims, configuration, and concurrent updates create more synchronization risk |
| PATH integration | Optional and explicit; can become stale when the drive path changes | Shims provide a clean command interface, but the shim directory is machine/environment-specific |
| Application data | Predictable for PAF apps; custom apps require preserve rules and may still write outside the folder | `persist` handles many apps, but data and configuration remain tied to the Scoop layout |
| PortableApps menu integration | Native for PAF packages; standalone apps can be refreshed into the menu | Not a PortableApps menu system; requires separate shortcuts or menu handling |
| Source maintenance | Custom providers and bucket manifests need maintenance | Shared Scoop manifests reduce individual maintenance for supported apps |
| Failure modes | A “portable” app may still write to the registry, user profile, services, or require drivers | A “portable” Scoop package may still have machine-specific dependencies or installer behavior |
| Reproducible setup | Excellent: carries the application collection together with accumulated settings and data; existing state can be either a benefit or a liability | Excellent for clean-slate provisioning through manifests, buckets, scripts, and repeatable installs |
| Best fit | A travelable or synchronized app collection | User-context software installation and management |

Both systems can reproduce a working environment well, but they reproduce different things. PortableApps is especially good at reproducing an environment with its accumulated use: preferences, profiles, extensions, templates, and other preserved data travel with the collection. That is ideal when I want to continue working as though the same personal environment were present. It can be a disadvantage when I want a clean, known-default state. Scoop is stronger for that clean-slate case because the desired application set can be declared and rebuilt without carrying previous user state unless persistence is intentionally restored.

## Advantages of PortableApps/PortableSideloader

### The directory is a transferable environment

The main benefit is that the application files, launchers, registry of managed apps, backups, and portable data can remain together. A second Windows system can use the same collection without first installing every application into that system.

This is especially valuable when:

- the same tools are needed on a personal and work computer;
- software installation requires administrator approval;
- the collection needs to run from removable storage or a synchronized folder;
- the preferred application is not available through the official PortableApps catalog;
- application data should travel with the application rather than remain in one user profile.

### It preserves the PortableApps user experience

The PortableApps menu, categories, launchers, and common root remain useful. PortableSideloader adds updates without requiring every custom application to be converted into a full PAF package.

### It is more honest about portability

PortableSideloader can preserve the actual folder and data layout rather than merely making an app easy to install. That distinction matters when the desired outcome is “copy this collection to another machine and continue working.”

## Disadvantages of PortableApps/PortableSideloader

### “Portable” is not guaranteed by the archive

Some applications called portable still write to the registry, `%APPDATA%`, `%LOCALAPPDATA%`, user profile folders, credential stores, services, or system directories. PortableApps.com also warns that standalone applications outside PortableApps Format may leave data behind or lose functionality when moved.

PortableSideloader can preserve known application paths, but it cannot make arbitrary software truly portable without application-specific launcher logic.

### Custom update rules are a maintenance obligation

When an app is not in Scoop or the PortableApps catalog, its version page, download URL, hash, and archive layout must be maintained. Vendor pages can change, mutable URLs can invalidate hashes, and some vendors block automated checks.

### Path and shell integration can become stale

If the collection moves from `C:` to `D:`, absolute PATH entries, shortcuts, file associations, and other external integrations may point to the old location. PortableSideloader can add explicit paths, but external Windows state is inherently less portable than the files inside the collection.

Git is a practical example: its portable distribution may use hardlinks during initialization. The destination filesystem and permissions therefore matter; portability does not remove all operating system constraints.

### The ecosystem is smaller for custom applications

Scoop has a large collection of community-maintained manifests and established conventions for `checkver`, `autoupdate`, dependencies, persistence, and version cleanup. PortableSideloader has to build or reuse those rules through its own bucket/provider model.

## Advantages of Scoop

### Excellent user-context installation ergonomics

Scoop provides a concise workflow for installing, updating, removing, and exposing applications to the shell. It avoids many traditional installer side effects and normally operates at user scope.

### Strong package-management conventions

Buckets, manifests, dependencies, versions, persistence, hashes, and update rules give Scoop a mature model for maintaining software. A private bucket also gives a clean way to add custom applications and share manifests across machines.

### Better fit for command-line software

For tools such as Git, compilers, SDKs, command-line utilities, language runtimes, and build tools, Scoop's shims and user-context PATH management are usually more convenient than manually managing application directories. Git is a good example: a portable Git installation can travel with the collection, but the Scoop version is usually the better choice when Git is primarily a shell tool. A user's installed software can be rebuilt from a script or a list of manifests.

### Cleaner separation from application collections

Scoop does not require every application to appear in the PortableApps menu, and it can manage tools that are not intended to be moved with personal data.

## Disadvantages of Scoop for this use case

### It is not a turnkey multi-computer collection

Moving a Scoop root is possible, but the target computer may need Scoop configuration, PATH/shim repair, bucket refreshes, and application-specific setup. It is closer to reproducing an environment than carrying an environment.

### It assumes a user-oriented shell environment

Scoop's shims and user environment variables are intentionally integrated into one Windows user profile. That is convenient for the current Windows user, but less convenient on a USB drive, a corporate computer, or a machine where the user profile and drive letter differ.

### Synchronization needs discipline

Synchronizing an active Scoop root or cache can produce conflicts, partial updates, or unnecessary downloads. The same warning applies to PortableApps, but Scoop has metadata and user-environment state outside the application directories.

### It does not solve portability of application data automatically

Scoop’s `persist` mechanism helps keep selected files across upgrades, but it is not the same as guaranteeing that all application state is contained in a transferable collection.

## Scenario results

| Scenario | Preferred approach | Reason |
|---|---|---|
| Rebuild a Windows user's software setup quickly | Scoop | Repeatable manifests, shims, dependencies, and updates |
| Carry a toolbox on a USB drive | PortableApps + PortableSideloader | The root is the transferable unit and the menu travels with it |
| Keep the same apps and settings on two PCs | PortableApps + PortableSideloader | Data and application directories can be synchronized together |
| Keep only command-line tools current | Scoop | PATH shims and package conventions are the main benefit |
| Use software on a locked-down work PC | PortableApps + PortableSideloader | Avoids many machine-wide installers, subject to corporate execution policy |
| Manage apps that are not truly portable | Scoop or normal installation | PortableApps cannot remove hidden machine dependencies |
| Maintain a private collection of GUI apps | PortableApps + private sideloader bucket | Menu integration and collection portability matter |
| Share manifests with a team | Scoop private bucket or repository | Scoop’s manifest model is familiar and easy to script |
| Switch often between drive letters or computers | PortableApps, with limited external integration | Keep PATH, shortcuts, and associations minimal or recreate them |

## Why this led to PortableSideloader

This project made sense once I put the requirements together:

1. The application collection should remain inside the PortableApps directory and visible through the PortableApps menu.
2. The collection should remain movable between supported Windows systems or usable from a synced directory.
3. Applications outside the official PortableApps catalog should still have repeatable update rules.
4. Application data should be preserved with the application wherever the software genuinely supports that behavior.
5. Updates should not require a machine-wide installer or a separate package-management environment.

PortableSideloader addresses those requirements by maintaining a local registry of apps, resolving their upstream versions, downloading and verifying new payloads, preserving configured data, and swapping the application directories in the PortableApps root.

This does not make every application truly portable. It preserves the collection model and gives each application an explicit place to describe its own update and preservation behavior. That is about as far as a general-purpose updater can go without writing a custom launcher for every application.

## Relationship to Scoop

Scoop is not excluded by this design. Both tools can be installed on the same systems:

- PortableApps/PortableSideloader can maintain the movable application collection.
- Scoop can install and maintain command-line utilities, SDKs, runtimes, developer tools, and other software in the current user's Windows context.

The important distinction is that Scoop is not a substitute for the PortableApps collection when the collection itself is the thing that needs to move or synchronize. Conversely, PortableSideloader does not need to replace Scoop's stronger user-context installation workflow.

Regardless of the tool, avoid synchronizing an application while it is running or updating. Treat PATH entries, shortcuts, file associations, credentials, caches, and services as machine-local state unless they are deliberately recreated.

The practical value of PortableSideloader is that it brings manifest-driven updates to the PortableApps collection model. Scoop generally provides the cleaner user-context installation experience, but it does not remove the need for a tool that maintains a movable, synchronized PortableApps collection.

## Why I built PortableSideloader instead of a custom ScoopSync tool

I also considered whether I should have built a ScoopSync-style tool instead. The starting point was practical: I already used PortableApps, I was already manually sideloading applications into it, and the missing capability was keeping those applications updated. Automating what I was already doing was the obvious next step. Replacing the collection model and building a new synchronization system around Scoop would have solved a different problem.

I could not find an established, maintained Scoop synchronization project that provides the same collection-level behavior. Scoop does provide built-in `export` and `import` commands, and there are personal scripts that export app and bucket lists for reconstruction. Those are useful, but they are provisioning and rebuild tools rather than a maintained synchronized collection.

The problem is not necessarily as complicated as building a complete synchronization system. If both computers use the same drive letter and directory layout, a simple tool could synchronize the Scoop root, including `apps`, `buckets`, `persist`, and `shims`. The cache could be synchronized as well, although it is not necessary because packages can be downloaded again. In that arrangement, the second computer would not need every application installed separately; it could use the synchronized application directories.

There would still be a small amount of per-user setup. Scoop normally keeps its configuration under the user's profile in `.config\scoop`, and the Scoop shims directory needs to be on that user's PATH. The second computer would therefore need Scoop's root path and shim path configured, either by installing Scoop once or by setting up those paths directly. The systems would also need compatible architectures and the same layout assumptions. This is much simpler than trying to synchronize arbitrary Windows environments, but it is still different from copying a PortableApps directory and expecting the collection to work without any user-profile setup.

The main operational risk would be synchronizing while Scoop is running or while an app is being updated. The same goes for PortableApps. A shared Scoop root would also need a policy for conflicts, bucket updates, and applications that rely on machine-specific settings or installers. Those are manageable constraints for a personal setup with matching systems, but they are reasons a general-purpose ScoopSync tool would need more than a file-copy command.

That is why I chose to develop PortableSideloader. PortableApps already defines the collection boundary, menu integration, and portability-oriented data conventions. PortableSideloader only needs to add the missing manifest-driven update layer for apps outside the official catalog. Scoop remains valuable on the same systems, especially for clean-slate software provisioning and command-line tools, but building a ScoopSync tool would have duplicated much of the collection and portability infrastructure that was already available through PortableApps.

## Sources

- [PortableApps.com Platform](https://portableapps.com/)
- [PortableApps.com Platform support and backup behavior](https://portableapps.com/support/platform)
- [What is a Portable App?](https://portableapps.com/about/what_is_a_portable_app)
- [PortableApps.com development resources](https://portableapps.com/development)
- [PortableApps.com Format specification](https://portableapps.com/development/portableapps.com_format)
- [Scoop project overview](https://github.com/ScoopInstaller/Scoop)
- [Scoop commands, including export and import](https://github.com/ScoopInstaller/Scoop/wiki/Commands)
- [Scoop global installs](https://github.com/ScoopInstaller/Scoop/wiki/Global-Installs)
- [Scoop folder layout](https://github.com/ScoopInstaller/Scoop/wiki/Scoop-Folder-Layout)
- [Scoop FAQ](https://github.com/ScoopInstaller/Scoop/wiki/FAQ)
