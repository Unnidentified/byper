# Limitations

## SIP

The bypass path attaches to `PowerUIAgent` with lldb. Stock SIP refuses root attach to system daemons. The package enables `DevToolsSecurity` and adds the console user to `_developer`, but that does not override SIP.

If the attach is refused, relax the debug restriction once in Recovery:

```bash
csrutil enable --without debug
```

Filesystem, kernel-extension and NVRAM protections stay on. Only the debugger-attach policy changes. Without it, `byper on` fails with "Not allowed to attach" and bypass cannot work on that machine.

## Debounce

`PowerUIAgent` debounces rapid opposite commands. Off then on within seconds can be swallowed or land 15 to 60 seconds late. byper works around it with detached workers and verify polls, but cannot remove the latency.

## Hardware and OS support

- Apple Silicon only. The build target is `arm64-apple-macos11.0`. Intel would need a universal2 build and untested SMC register maps.
- macOS 11 or newer. App Intents need macOS 13.
- The Liquid Glass popover needs macOS 26. Older systems, and anyone with Reduce Transparency on, get the previous dark solid shell. Nothing else changes.
- The register signatures (`MoO`, `NCR`, rail keys) were mapped on specific macOS versions. A major update can shift them. The verify poll surfaces that as "enabled but not holding".

## Precision

The hold lands at whatever state of charge the battery is at when you engage it. There is no firmware charge-limit register being set, because the firmware rejects those writes. "Hold at 80%" means "engage when the battery reads 80%".

The threshold automation is not offered. `checkAutoBypassThreshold()` disables the flag on launch because the trigger only engaged while freshly toggled and had reliability issues. Slow Charge is also not offered: its duty cycle could re-engage bypass after a while, so the setter forces the flag off. Do not document either as a live feature.

## Distribution

The app is ad-hoc signed, not Developer ID signed. Gatekeeper blocks quarantine-flagged copies until Open Anyway or `xattr -dr com.apple.quarantine`.

No credentials are embedded in the repository. The non-root dev path reads `BYP_SUDO_PASS` from the environment.

## Single-user assumptions

Two paths still assume the original developer's account:

- `src/app/AppDelegate.swift` has `/Users/gefaass/Desktop/Documents/agent stuff/macos-ch.bypass #2/byper.app` and `bin/byper` in `runPrivilegedInstall`.
- `src/main.c` falls back to `/Users/gefaass` when it looks for the Desktop export path.

The package path works without them. A source install under a different account may need those literals changed.
