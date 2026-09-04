#!/bin/bash
# ============================================================
#  macos-ch.bypass — install.sh
#  Installs 'byper', 'byp', 'chbypass', 'byper-mon.command', 'byper.app',
#  and shell completions (Zsh / Bash)
# ============================================================

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DEST="/usr/local/bin/byper"
BYP_DEST="/usr/local/bin/byp"
CHBYPASS_DEST="/usr/local/bin/chbypass"
MON_DEST="/usr/local/bin/byper-mon.command"
BYP_MON_DEST="/usr/local/bin/byp-mon.command"
APP_DEST="/Applications/byper.app"

echo "[*] Building native CLI binary and menu bar companion app (byper)..."
# Building under root leaves root-owned artifacts in the project bundle and
# every later user-level rebuild fails with "can't write output file". Run the
# build as the invoking user, and if the script itself was sudo'd, hand the
# artifacts back afterwards. Only the install steps below need privileges.
if [ -n "$SUDO_USER" ] && [ "$(id -u)" = "0" ]; then
    sudo -u "$SUDO_USER" make -C "$DIR" all
    chown -R "$SUDO_USER" "$DIR/byper.app" "$DIR/bin" 2>/dev/null || true
else
    make -C "$DIR" all
fi

echo "[*] Installing CLI tools to /usr/local/bin..."
sudo mkdir -p /usr/local/bin
sudo cp -f "$DIR/bin/byper" "$BIN_DEST"
sudo chown root:wheel "$BIN_DEST"
sudo chmod 4755 "$BIN_DEST"
sudo codesign -s - -f "$BIN_DEST" >/dev/null 2>&1 || true
sudo ln -sf "$BIN_DEST" "$BYP_DEST"
sudo ln -sf "$BIN_DEST" "$CHBYPASS_DEST"

echo "[*] Installing byper-mon.command..."
sudo cp -f "$DIR/bin/byper-mon.command" "$MON_DEST"
sudo chmod 755 "$MON_DEST"
sudo ln -sf "$MON_DEST" "$BYP_MON_DEST"

echo "[*] Installing Shell Auto-Completions..."
sudo mkdir -p /usr/local/share/zsh/site-functions /usr/local/share/bash-completion/completions
if [ -f "$DIR/completions/_byp" ]; then
    sudo cp -f "$DIR/completions/_byp" /usr/local/share/zsh/site-functions/_byper
    sudo cp -f "$DIR/completions/_byp" /usr/local/share/zsh/site-functions/_byp
    sudo chmod 644 /usr/local/share/zsh/site-functions/_byper /usr/local/share/zsh/site-functions/_byp
fi
if [ -f "$DIR/completions/byp.bash" ]; then
    sudo cp -f "$DIR/completions/byp.bash" /usr/local/share/bash-completion/completions/byper
    sudo cp -f "$DIR/completions/byp.bash" /usr/local/share/bash-completion/completions/byp
    sudo chmod 644 /usr/local/share/bash-completion/completions/byper /usr/local/share/bash-completion/completions/byp
fi

echo "[*] Installing byper.app to /Applications..."
pkill -f "byper.app" || true
pkill -f "/Applications/byper.app" || true
sudo rm -rf "$APP_DEST" /Applications/byp.app
sudo cp -R "$DIR/byper.app" "$APP_DEST"
sudo chown -R root:wheel "$APP_DEST"
sudo chmod 4755 "$APP_DEST/Contents/Resources/byper"

sudo rm -f /tmp/byp.state

echo "[*] Launching byper.app..."
open "$APP_DEST"

echo ""
echo "[OK] Installation complete. Bypass is OFF by default (Normal Charging preserved)."
echo "Usage:"
echo "  [+] Live Telemetry Monitor:       byper (or byp)"
echo "  [+] Enable Pure Bypass (On Hold): byper on"
echo "  [+] Disable Bypass (Full Charge): byper off"
echo "  [+] NDJSON Live Stream:           byper stream (or byper json --watch)"
echo "  [+] Hardware & MagSafe PDO:       byper p"
echo "  [+] Status Summary:               byper s"
echo "  [+] Toggle Hold / Charging:       byper t"
echo "  [+] Menu Bar Companion GUI:       open -a byper"
echo ""
