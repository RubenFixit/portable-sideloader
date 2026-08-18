# RubenFixit Scoop bucket

This directory is the personal Scoop-compatible bucket used by portable-sideloader.

Add one JSON manifest per app, for example `bucket/my-app.json`. The manifest should follow Scoop's
standard format and include at least `version`, `description`, `homepage`, `license`, and `url`.
Use `checkver` and `autoupdate` whenever upstream provides a stable version source.

The sideloader reads these manifests directly from GitHub; Scoop can consume the same directory as
a bucket:

```powershell
scoop bucket add rubenfixit https://github.com/RubenFixit/portable-sideloader
scoop install rubenfixit/my-app
```

When a manifest is broadly useful and meets Scoop's contribution criteria, submit it upstream and
remove the duplicate here once the upstream bucket carries it.

Manifest updates are automated by `.github/workflows/update-bucket.yml`, which runs daily and can
also be dispatched manually. It commits only changed files under `bucket\`.

## Maintenance notes

`usb-tree-view.json` uses the vendor's rolling latest-download URL. When `checkver` finds a new
version, update both `version` and `hash`; the vendor does not publish a versioned archive or a
separate checksum feed.
