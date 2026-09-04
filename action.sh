#!/bin/bash
# ============================================================
#  macos-ch.bypass — action.sh (Live Status & Control Menu)
#  macOS Charging Bypass & Hardware Telemetry Addon Module
# ============================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/bin/byper"

# Auto-compile if missing or out of date
if [ ! -f "$BIN" ]; then
    echo "[*] Compiling byper native binary..."
    make -C "$DIR" >/dev/null 2>&1
    if [ ! -f "$BIN" ]; then
        echo "[ERROR] Build failed. Please run 'make' manually."
        exit 1
    fi
fi

# Pass-through to binary
exec "$BIN" "$@"
