# Limitations

## SIP is the hard boundary

byper's bypass path injects into `PowerUIAgent` with lldb. On a stock SIP configuration this works only where the system's developer-tool policy allows root attach to system daemons. Every non-debugger alternative has been probed and ruled out: there is no supported surface for "stop charging at current level," and direct SMC writes to the charge-limit keys are rejected by the firmware (tested: `CHBI` writes don't stick). If a Mac's build refuses the attach ("Not allowed to attach"), byper cannot bypass on it without relaxing SIP, which is out of scope for this project.

The PKG mitigates what it can (DevToolsSecurity + `_developer` group in postinstall), but that does not guarantee attach on every macOS build.

## OS-side toggle debounce

PowerUIAgent debounces rapid opposite commands: toggling off then on within seconds can be swallowed or land 15–60 s late. This is OS behavior; byper works around it with async workers and verify-polls, but cannot eliminate the latency.

## Hardware / OS support

- **Apple Silicon (M1–M4) only.** Builds target `arm64-apple-macos11.0`. Intel Macs would need a universal2 build and untested SMC register maps.
- **macOS 11+** for the CLI; App Intents features need macOS 13+.
- Register signatures (mode-of-operation values, `NCR` reasons, rails keys) were empirically mapped on specific macOS versions. Major macOS updates may shift them; the verify-poll will surface it as "enabled but not holding."

## Precision

- The hold lands at *whatever SoC the battery is at when you engage*. There is no firmware charge-limit register being set (firmware rejects writes), so "hold at 80%" means "watch the threshold automation and engage as you cross 80%."
- Slow Charge moves the battery in a 20 s hold / 40 s burst duty cycle; it is a trickle, not a linear set-point.
- Engine state can lag UI taps by up to ~45 s while the lldb worker runs.

## Distribution

- Ad-hoc signed, not Developer ID. Gatekeeper hard-blocks quarantine-flagged copies (WhatsApp/AirDrop transfer) until "Abrir igualmente" or `xattr -dr`.
- No credentials are embedded anywhere in the source; the non-root dev path reads `BYP_SUDO_PASS` from the environment instead (see [ARCHITECTURE.md](ARCHITECTURE.md#dev-path-authentication)).

## Single-user assumptions

Paths like `/Users/gefaass` appear in a few fallbacks (`src/main.c`, self-updater paths in `AppDelegate.swift`, asset-resolver fallback dir). On other machines the PKG path works without them; a source install on a different user account may need those literals adjusted.
