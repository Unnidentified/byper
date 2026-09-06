#!/bin/bash
# Build byper-installer.pkg — guided Installer.app package (run `make app` first).
# VANILLA branch build: the app is compiled with -D VANILLA by the Makefile, so
# this script just packages what `make app` produced. Two paths presented in the
# Installation Type pane:
#   • Upgrade / clean reinstall (keeps app settings)
#   • Uninstall (removes everything, including settings)
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# Component 1: upgrade payload (fresh app; settings kept)
mkdir -p "$W/payload"
cp -R "$DIR/byper.app" "$W/payload/"
mkdir -p "$W/payload/byper.app/Contents/Resources/completions"
cp "$DIR"/completions/_byp "$DIR"/completions/byp.bash "$W/payload/byper.app/Contents/Resources/completions/"

mkdir -p "$W/scripts"
cp "$DIR"/pkg/preinstall "$DIR"/pkg/postinstall "$W/scripts/"
chmod +x "$W"/scripts/*

cd "$W"
pkgbuild --root payload --scripts scripts --identifier com.gefaass.byper.vanilla \
         --version 2.2.0 --install-location /Applications byper-pkg-component.pkg

# Component 2: uninstaller (no payload, script-only)
mkdir -p "$W/uninstall-scripts"
cp "$DIR"/pkg/uninstall-postinstall "$W/uninstall-scripts/postinstall"
chmod +x "$W"/uninstall-scripts/postinstall
pkgbuild --nopayload --scripts uninstall-scripts --identifier com.gefaass.byper.uninstall \
         --version 2.2.0 byper-uninstall-component.pkg

productbuild --distribution "$DIR/pkg/Distribution.xml" --package-path . \
             --resources "$DIR/pkg" byper-installer.pkg

# Brand the .pkg file with the app icon in Finder, deliver to the project folder.
# Applied here, during the build (NSWorkspace one-call: writes the -16455 icns
# resource, sets kHasCustomIcon, notifies Finder). Never injected post-hoc.
OUT="$DIR/byper-installer.pkg"
rm -f "$OUT"
cp byper-installer.pkg "$OUT"
ICON_SRC="$DIR/assets/icon.png"
[ ! -f "$ICON_SRC" ] && ICON_SRC="$DIR/src/app/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    swift -e '
        import AppKit
        let args = CommandLine.arguments
        guard args.count >= 3, let img = NSImage(contentsOfFile: args[1]) else { exit(1) }
        NSWorkspace.shared.setIcon(img, forFile: args[2], options: [])
    ' "$ICON_SRC" "$OUT" >/dev/null 2>&1 || true
fi

# Wrap in a DMG: bare files lose resource forks over HTTP, a DMG filesystem
# preserves them, so the custom icon survives the download.
DMG_STAGE="$W/dmg"
mkdir -p "$DMG_STAGE"
ditto "$OUT" "$DMG_STAGE/byper-installer.pkg"
DMG_OUT="$DIR/byper-installer.dmg"
rm -f "$DMG_OUT"
hdiutil create -volname "byper vanilla 2.2.0" -srcfolder "$DMG_STAGE" -format UDZO -o "$DMG_OUT" >/dev/null 2>&1
rm -rf "$DMG_STAGE"

echo "[OK] $OUT"
echo "[OK] $DMG_OUT"
