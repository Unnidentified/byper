#!/bin/bash
# Build byper-vanilla-installer.pkg — vanilla variant (bypass charge, powersave,
# caffeinate, settings). The icon is applied to the .pkg as part of THIS build
# (never injected afterwards), and the finished pkg is wrapped in a DMG so the
# Finder custom icon survives download (HTTP strips resource forks from bare
# files; a DMG filesystem carries them intact).
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# Build the vanilla app first (icon bundled into the .app from the start)
cd "$DIR"
make vanilla >/dev/null

# Component 1: upgrade payload (fresh app; settings kept)
mkdir -p "$W/payload"
cp -R "$DIR/byper-vanilla.app" "$W/payload/"
mkdir -p "$W/payload/byper-vanilla.app/Contents/Resources/completions"
cp "$DIR"/completions/_byp "$DIR"/completions/byp.bash "$W/payload/byper-vanilla.app/Contents/Resources/completions/"

mkdir -p "$W/scripts"
cp "$DIR"/pkg/preinstall "$DIR"/pkg/postinstall "$W/scripts/"
chmod +x "$W"/scripts/*

cd "$W"
pkgbuild --root payload --scripts scripts --identifier com.gefaass.byper.vanilla \
         --version 2.2.0 --install-location /Applications byper-vanilla-component.pkg

# Component 2: uninstaller (no payload, script-only)
mkdir -p "$W/uninstall-scripts"
cp "$DIR"/pkg/uninstall-postinstall "$W/uninstall-scripts/postinstall"
chmod +x "$W"/uninstall-scripts/postinstall
pkgbuild --nopayload --scripts uninstall-scripts --identifier com.gefaass.byper.uninstall \
         --version 2.2.0 byper-vanilla-uninstall-component.pkg

productbuild --distribution "$DIR/pkg/Distribution-vanilla.xml" --package-path . \
             --resources "$DIR/pkg" byper-vanilla-installer.pkg

# Deliver to the project folder
OUT="$DIR/byper-vanilla-installer.pkg"
cp byper-vanilla-installer.pkg "$OUT"

# Brand the .pkg with the app icon AS PART OF THE BUILD (NSWorkspace one-call:
# writes the -16455 icns resource, sets kHasCustomIcon, notifies Finder).
swift -e '
    import AppKit
    let args = CommandLine.arguments
    guard args.count >= 3, let img = NSImage(contentsOfFile: args[1]) else { exit(1) }
    NSWorkspace.shared.setIcon(img, forFile: args[2], options: [])
' "$DIR/assets/icon.png" "$OUT" || true

# Wrap in a DMG: bare files lose resource forks over HTTP, a DMG filesystem
# preserves them, so the custom icon survives the download.
DMG_STAGE="$W/dmg"
mkdir -p "$DMG_STAGE"
ditto "$OUT" "$DMG_STAGE/byper-vanilla-installer.pkg"
DMG_OUT="$DIR/byper-vanilla-installer.dmg"
rm -f "$DMG_OUT"
hdiutil create -volname "byper vanilla 2.2.0" -srcfolder "$DMG_STAGE" -format UDZO -o "$DMG_OUT" >/dev/null 2>&1
rm -rf "$DMG_STAGE"

echo "[OK] $OUT"
echo "[OK] $DMG_OUT"
