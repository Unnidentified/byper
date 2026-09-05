# Setting Custom File Icons on macOS (`.pkg` / files / folders)

How to brand an arbitrary file (e.g. `installer.pkg`) with a custom icon in Finder, and why the obvious approaches fail.

## The problem

Common attempts fail silently or fall back to the generic package icon:

1. **`Rez` with `read 'icns' (128)`.** Resource ID `128` is only the default for application bundles in Classic Mac OS; Finder's custom-icon subsystem **completely ignores** resource ID 128.
2. **`DeRez` directly on a `.icns`.** A raw `.icns` is a data-fork binary, not a Mac OS resource-fork file, so DeRez fails with `eofErr (-39)`.
3. **Transfers that strip metadata.** Downloading over HTTP, Git, or extracting standard zip archives drops macOS extended attributes and resource forks (`com.apple.ResourceFork` / `com.apple.FinderInfo`), reverting the file to `avbstclinmedz` (lowercase `c` = no custom icon).

## The OS-level requirements

For Finder to display a custom icon on a non-bundle file, three things must hold:

1. **Extended attribute `com.apple.FinderInfo`.** Bit `0x0400` (`kHasCustomIcon`) enabled in the `fdFlags` at byte offset 8–9. Inspect with `GetFileInfo -a <file>`: a **capital `C`** in the flags string (e.g. `avbstClinmedz`) means the bit is set; lowercase `c` means it isn't.
2. **Resource fork `com.apple.ResourceFork`.** Must contain a resource of type `'icns'` with the exact ID **`-16455`** (`kCustomIconResource`, `0xBFC9`).
3. **LaunchServices / Finder cache.** The workspace must be notified so Finder re-renders the icon immediately (no reboot, no `killall Finder`).

## The robust native solution (Cocoa / NSWorkspace)

Skip the deprecated Carbon tools (`Rez`, `DeRez`, `SetFile`) entirely. Every modern macOS system with Command Line Tools ships the native Swift runtime and Cocoa `AppKit`.

`NSWorkspace.shared.setIcon(_:forFile:options:)` handles the entire pipeline in one call:

- Accepts `.png`, `.icns`, `.jpg`, or `.tiff` directly.
- Auto-generates all required mipmap resolutions (16×16 up to 1024×1024 Retina).
- Writes the resource fork as `icns (-16455)`.
- Sets the `kHasCustomIcon` bit in `com.apple.FinderInfo`.
- Broadcasts the workspace change so Finder/LaunchServices refresh instantly.

### One-line command (terminal / scripts)

```bash
swift -e '
    import AppKit
    let args = CommandLine.arguments
    guard args.count >= 3, let img = NSImage(contentsOfFile: args[1]) else { exit(1) }
    NSWorkspace.shared.setIcon(img, forFile: args[2], options: [])
' "/path/to/icon.png" "/path/to/target.pkg"
```

## Verification checklist

1. `GetFileInfo -a /path/to/file`. Look for the **capital `C`** in the flags (`avbstClinmedz`).
2. `ls -l@ /path/to/file`. Confirm `com.apple.FinderInfo` and `com.apple.ResourceFork` exist.
3. `installer -pkginfo -pkg /path/to/file.pkg`. Confirm the package payload is still valid and untouched.

## Where this lives in this repo

`pkg/build_pkg.sh` brands `byper-installer.pkg` with `assets/icon.png` via exactly this NSWorkspace call after `productbuild`. See the end of that script.
