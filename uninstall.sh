#!/bin/bash
# ============================================================
#  macos-ch.bypass - uninstall.sh
#  Removes everything install.sh installs (CLI, GUI, completions)
# ============================================================

set -e

echo "[*] Quitting byper.app..."
pkill -f "byper.app" 2>/dev/null || true
pkill -f "/Applications/byper.app" 2>/dev/null || true
sleep 1

# Release any bypass hold and clear Low Power Mode while the CLI still exists,
# so the machine returns to stock power behavior before the tool is deleted.
# Same reset the package uninstaller performs.
echo "[*] Releasing bypass hold and clearing Low Power Mode..."
if [ -x /usr/local/bin/byper ]; then
    AC_ATTACHED=$(/usr/local/bin/byper json 2>/dev/null | grep -o '"acAttached": *true' || true)
    if [ -n "$AC_ATTACHED" ]; then
        /usr/local/bin/byper off >/dev/null 2>&1 || true
        sleep 1
        FLOW=$(/usr/local/bin/byper s 2>/dev/null | head -1)
        case "$FLOW" in
            *BYPASS*|*"ON HOLD"*|*hold*)
                /usr/local/bin/byper off >/dev/null 2>&1 || true
                ;;
        esac
    fi
    /usr/local/bin/byper lpm off >/dev/null 2>&1 || true
else
    echo "[!] byper CLI not found, cannot release a hold through it."
fi
if ! sudo /usr/bin/pmset -a lowpowermode 0 >/dev/null 2>&1; then
    echo "[!] Could not clear Low Power Mode. Run: sudo pmset -a lowpowermode 0"
fi

echo "[*] Removing CLI tools from /usr/local/bin..."
sudo rm -f /usr/local/bin/byper /usr/local/bin/byp /usr/local/bin/chbypass \
    /usr/local/bin/byper-mon.command /usr/local/bin/byp-mon.command /tmp/byp.state

echo "[*] Removing shell completions..."
sudo rm -f /usr/local/share/zsh/site-functions/_byper /usr/local/share/zsh/site-functions/_byp \
    /usr/local/share/bash-completion/completions/byper /usr/local/share/bash-completion/completions/byp

echo "[*] Removing byper.app from /Applications..."
sudo rm -rf /Applications/byper.app /Applications/byp.app

echo "[OK] Uninstallation complete."
