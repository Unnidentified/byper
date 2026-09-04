#!/bin/bash
# ============================================================
#  macos-ch.bypass — uninstall.sh (Standalone CLI)
# ============================================================

set -e

echo "[*] Removing CLI tools from /usr/local/bin..."
sudo rm -f /usr/local/bin/chbypass /usr/local/bin/byp /usr/local/bin/byp-mon.command /tmp/byp.state
echo "[OK] Uninstallation complete."
