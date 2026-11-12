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
- The register signatures (`NCR`, rail keys) were mapped on specific macOS versions. A major update can shift them. The verify poll surfaces that as "enabled but not holding".

## Lid close

The caffeinate assertions do not survive a lid close. `PreventUserIdleSystemSleep`
and `PreventUserIdleDisplaySleep` prevent idle sleep, and `pmset -g log` shows the
machine entering `Clamshell Sleep` with both of them held. `caffeinate -s` is not
an alternative: it creates a `PreventSystemSleep` assertion that powerd does not
count, so the system-wide counter stays at 0 while it is held.

The only switch that overrides a lid close is `SleepDisabled`, which
`pmset -a disablesleep` writes. It needs root, so it goes through the SUID CLI.
Two consequences are worth knowing before arming "On lid close":

- It is a global setting, not an assertion. While it is set the machine does not
  sleep at all, including idle sleep with the lid open. That is what the switch
  does, and it is why byper holds it only while the condition is armed.
- It is not owned by a process. A crash or a kill leaves it set with nothing to
  release it. byper clears it on disarm, on quit and on the next launch when it
  finds it left behind, and it never clears a flag it did not set. If a machine
  is left unable to sleep, `sudo pmset -a disablesleep 0` restores it.

Whether the built-in display stays lit with the lid shut is decided by macOS, not
by byper. powerd's own trace puts the display power-off inside the Clamshell
Sleep path, after the sleep is committed, so suppressing the sleep is expected to
leave the panel on. That expectation has not been confirmed on hardware here: it
needs a physical lid close with the flag set.

## Precision

The hold lands at whatever state of charge the battery is at when you engage it. There is no firmware charge-limit register being set, because the firmware rejects those writes. "Hold at 80%" means "engage when the battery reads 80%".

The threshold automation is not offered. `checkAutoBypassThreshold()` disables the flag on launch because the trigger only engaged while freshly toggled and had reliability issues. Slow Charge is also not offered: its duty cycle could re-engage bypass after a while, so the setter forces the flag off. Do not document either as a live feature.

## Distribution

The app is ad-hoc signed, not Developer ID signed. Gatekeeper blocks quarantine-flagged copies until Open Anyway or `xattr -dr com.apple.quarantine`.

No credentials are embedded in the repository. The non-root dev path reads `BYP_SUDO_PASS` from the environment.
