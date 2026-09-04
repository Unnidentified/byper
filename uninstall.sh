#!/bin/bash
# ============================================================
#  macos-ch.bypass — uninstall.sh
#  Removes everything install.sh installs (CLI, GUI, completions)
# ============================================================

set -e

echo "[*] Quitting byper.app..."
pkill -f "byper.app" 2>/dev/null || true
pkill -f "/Applications/byper.app" 2>/dev/null || true

echo "[*] Removing CLI tools from /usr/local/bin..."
sudo rm -f /usr/local/bin/byper /usr/local/bin/byp /usr/local/bin/chbypass \
    /usr/local/bin/byper-mon.command /usr/local/bin/byp-mon.command /tmp/byp.state

echo "[*] Removing shell completions..."
sudo rm -f /usr/local/share/zsh/site-functions/_byper /usr/local/share/zsh/site-functions/_byp \
    /usr/local/share/bash-completion/completions/byper /usr/local/share/bash-completion/completions/byp

echo "[*] Removing byper.app from /Applications..."
sudo rm -rf /Applications/byper.app /Applications/byp.app

echo "[OK] Uninstallation complete."
