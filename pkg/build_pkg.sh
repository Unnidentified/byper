#!/bin/bash
# Build byper installer packages (guided Installer.app package).
# Supports optional label argument, e.g. `build_pkg.sh test` produces
# `byper-test.pkg` and `byper-test.dmg` labeled "byper 2.2.9 (test)".
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

LABEL="${1:-}"
if [ -n "$LABEL" ]; then
    PKG_NAME="byper-${LABEL}.pkg"
    DMG_NAME="byper-${LABEL}.dmg"
    TITLE="byper 2.2.9 (${LABEL})"
    VERSION="2.2.9-${LABEL}"
    IDENTIFIER="com.gefaass.byper.${LABEL}"
else
    PKG_NAME="byper-installer.pkg"
    DMG_NAME="byper-installer.dmg"
    TITLE="byper 2.2.9"
    VERSION="2.2.9"
    IDENTIFIER="com.gefaass.byper"
fi

# Component 1: upgrade payload (fresh app; settings kept)
mkdir -p "$W/payload"
cp -R "$DIR/byper.app" "$W/payload/"
mkdir -p "$W/payload/byper.app/Contents/Resources/completions"
cp "$DIR"/completions/_byp "$DIR"/completions/byp.bash "$W/payload/byper.app/Contents/Resources/completions/"

mkdir -p "$W/scripts"
cp "$DIR"/pkg/preinstall "$DIR"/pkg/postinstall "$W/scripts/"
chmod +x "$W"/scripts/*

cd "$W"
pkgbuild --root payload --scripts scripts --identifier "$IDENTIFIER" \
         --version "$VERSION" --install-location /Applications byper-pkg-component.pkg

# Component 2: uninstaller (no payload, script-only)
mkdir -p "$W/uninstall-scripts"
cp "$DIR"/pkg/uninstall-postinstall "$W/uninstall-scripts/postinstall"
chmod +x "$W"/uninstall-scripts/postinstall
pkgbuild --nopayload --scripts uninstall-scripts --identifier "${IDENTIFIER}.uninstall" \
         --version "$VERSION" byper-uninstall-component.pkg

DIST_XML="$W/Distribution.xml"
sed "s|<title>byper 2.2.9</title>|<title>$TITLE</title>|g" "$DIR/pkg/Distribution.xml" > "$DIST_XML"

productbuild --distribution "$DIST_XML" --package-path . \
             --resources "$DIR/pkg" "$PKG_NAME"

# Brand the .pkg file with the app icon in Finder, deliver to the project folder.
OUT="$DIR/$PKG_NAME"
rm -f "$OUT"
cp "$PKG_NAME" "$OUT"
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
ditto "$OUT" "$DMG_STAGE/$PKG_NAME"
DMG_OUT="$DIR/$DMG_NAME"
rm -f "$DMG_OUT"
hdiutil create -volname "$TITLE" -srcfolder "$DMG_STAGE" -format UDZO -o "$DMG_OUT" >/dev/null 2>&1
rm -rf "$DMG_STAGE"

echo "[OK] $OUT"
echo "[OK] $DMG_OUT"
