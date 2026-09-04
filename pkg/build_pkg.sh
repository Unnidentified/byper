#!/bin/bash
# Build byper-installer.pkg — guided Installer.app package (run `make app` first).
# Two paths presented in the Installation Type pane:
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
pkgbuild --root payload --scripts scripts --identifier com.gefaass.byper \
         --version 2.1.0 --install-location /Applications byper-pkg-component.pkg

# Component 2: uninstaller (no payload, script-only)
mkdir -p "$W/uninstall-scripts"
cp "$DIR"/pkg/uninstall-postinstall "$W/uninstall-scripts/postinstall"
chmod +x "$W"/uninstall-scripts/postinstall
pkgbuild --nopayload --scripts uninstall-scripts --identifier com.gefaass.byper.uninstall \
         --version 2.1.0 byper-uninstall-component.pkg

productbuild --distribution "$DIR/pkg/Distribution.xml" --package-path . \
             --resources "$DIR/pkg" byper-installer.pkg

# Brand the .pkg file with the app icon in Finder, deliver to Desktop
OUT="$HOME/Desktop/byper-installer.pkg"
rm -f "$HOME/Desktop/byper-installer.pkg" "$HOME/Desktop/byper.pkg"
if DeRez -only icns "$DIR/src/app/AppIcon.icns" > icon.rsrc 2>/dev/null; then
    cp byper-installer.pkg "$OUT"
    Rez -append icon.rsrc -o "$OUT" && SetFile -a C "$OUT"
else
    cp byper-installer.pkg "$OUT"
fi
echo "[OK] $OUT"
