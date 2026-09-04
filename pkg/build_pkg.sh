#!/bin/bash
# Build byper.pkg — guided Installer.app package (run `make app` first).
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

mkdir -p "$W/payload"
cp -R "$DIR/byper.app" "$W/payload/"
mkdir -p "$W/payload/byper.app/Contents/Resources/completions"
cp "$DIR"/completions/_byp "$DIR"/completions/byp.bash "$W/payload/byper.app/Contents/Resources/completions/"

mkdir -p "$W/scripts"
cp "$DIR"/pkg/preinstall "$DIR"/pkg/postinstall "$W/scripts/"
chmod +x "$W"/scripts/*

cd "$W"
pkgbuild --root payload --scripts scripts --identifier com.gefaass.byper \
         --version 3.5.0 --install-location /Applications byper-component.pkg
productbuild --distribution "$DIR/pkg/Distribution.xml" --package-path . \
             --resources "$DIR/pkg" byper.pkg

# Brand the .pkg file with the app icon in Finder
sips -i "$DIR/src/app/AppIcon.icns" >/dev/null 2>&1 || true
if [ -f "$HOME/Desktop/icon.png" ]; then
    sips -i "$HOME/Desktop/icon.png" >/dev/null 2>&1
    DeRez -only icns "$HOME/Desktop/icon.png" > icon.rsrc 2>/dev/null && \
    { cp byper.pkg "$HOME/Desktop/byper.pkg"; Rez -append icon.rsrc -o "$HOME/Desktop/byper.pkg" && SetFile -a C "$HOME/Desktop/byper.pkg"; }
else
    cp byper.pkg "$HOME/Desktop/byper.pkg"
fi
echo "[OK] ~/Desktop/byper.pkg"
