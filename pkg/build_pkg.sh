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
cp byper-installer.pkg "$OUT"
# A raw .icns is a data-fork icon file, so DeRez can't read it directly. Wrap it
# into a real resource fork with a Rez 'read' statement, DeRez THAT back to Rez
# source text, then append it as the pkg's custom-icon resource.
cat > "$W/appicon.rdef" <<REZ
read 'icns' (128) "appicon.icns";
REZ
cp "$DIR/src/app/AppIcon.icns" "$W/appicon.icns"
if (cd "$W" && Rez appicon.rdef -o appicon.rsrc >/dev/null 2>&1 \
      && DeRez -only icns appicon.rsrc > icon.rsrc 2>/dev/null); then
    Rez -append "$W/icon.rsrc" -o "$OUT" && SetFile -a C "$OUT"
fi
echo "[OK] $OUT"
