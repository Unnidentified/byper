# Troubleshooting

## "Bypass says enabled but the battery still charges"

The SUID bit is missing or the binary isn't root-owned. This failure mode is silent: the CLI prints `enabled [✓]` and nothing happens on the hardware.

```bash
ls -la /usr/local/bin/byper /Applications/byper.app/Contents/Resources/byper
# must show: -rwsr-xr-x  root:wheel
```

Fix: re-run `sudo ./install.sh`, or use the in-app admin prompt (it runs `src/app/install_helper.c` which repairs ownership), or apply the chmod/chown by hand (see [INSTALL.md](INSTALL.md#the-suid-requirement)).

## `ld: can't write output file` when rebuilding

Almost always root-owned build artifacts from a previous sudo'd build — not a busy file. `install.sh` now builds as the invoking user to prevent this; if it already happened:

```bash
sudo chown -R "$USER" bin byper.app
```

Then `make clean && make`. Always confirm `bin/byper`'s mtime is newer than the sources before debugging "my change didn't ship."

## lldb attach fails / "Not allowed to attach"

The bypass needs to attach to `PowerUIAgent` as root, which macOS gates behind developer-tool policy. Things that matter:

1. **DevToolsSecurity enabled** — the PKG postinstall runs `DevToolsSecurity -enable` and adds you to `_developer`; do the same manually on machines installed by hand:
   ```bash
   sudo DevToolsSecurity -enable
   sudo dseditgroup -o edit -a "$USER" -t user _developer
   ```
2. **Command Line Tools installed** — `xcode-select --install` (the tool auto-installs if missing; check `xcode-select -p`).
3. **SIP still blocks some attach policies** — on stock SIP, attach to system daemons can be refused per-build regardless of DevToolsSecurity. If `byper on` keeps failing:
   ```bash
   BYP_LLDB_DEBUG=1 byper on   # writes /tmp/byp_lldb_debug.log (wiped on reboot)
   ```
   and check the unified log for PowerUIAgent attach denials. If your build refuses root attach, there is currently no non-SIP workaround (see [LIMITATIONS.md](LIMITATIONS.md)).

## Toggle seems to hang or does nothing for ~30–60 s

Two known causes:

- **The apply is asynchronous.** The lldb worker runs detached; UI/engine fields can lag up to ~45 s behind a tap. The verify-poll gates truth — wait for the state to flip rather than re-tapping.
- **OS-side debounce.** PowerUIAgent swallows rapid opposite toggles (off → on within seconds) and lands the second one late. This is an OS behavior, not a bug in byper.

## Bypass re-engages by itself / Slow Charge fights Bypass

They're mutually exclusive at four layers. If an automation (plug-in, login, display, threshold) re-engages bypass while Slow Charge is enabled, update to a build with `engageAutoHoldOnPlug` gating (all auto-engage paths yield to Slow Charge). Launch also reseeds stale holds so a previous session's bypass can't deadlock the duty cycle.

## App won't open after WhatsApp/AirDrop transfer ("no se puede abrir", hard block)

Quarantine on an ad-hoc–signed app. Either System Settings → *Privacidad y seguridad* → **Abrir igualmente**, or:

```bash
xattr -dr com.apple.quarantine /Applications/byper.app
```

## Popover UI issues

- **Rows overflow their row** — inline numbers next to the row switches need the switch's `frame` clamped; `scaleEffect(0.70)` does not shrink layout footprint.
- **Popover doesn't resize when a section expands** — every expandable flag must be in the `Publishers.Merge` in `AppDelegate.applicationDidFinishLaunching`.
- **Timers stall with menus open / screen asleep** — add timers to `RunLoop.main` with `.common` mode; a long-lived `beginActivity` assertion covers threshold polling while the display sleeps.
- **Contrast on light wallpapers** — the popover has a near-opaque dark base; if text looks washed out, check you're on the bundled fonts (corrupt TTFs fall back to `.custom()` silently — the shipped FiraCode files are verified).

## Diagnostics cheat sheet

```bash
byper s                      # is the CLI alive and reading hardware?
ls -la /usr/local/bin/byper  # SUID intact?
pgrep -fl PowerUIAgent       # daemon running?
pgrep -fl lldb               # worker stuck? (should be transient)
BYP_LLDB_DEBUG=1 byper on    # verbose attach log → /tmp/byp_lldb_debug.log
log show --last 5m --predicate 'process == "PowerUIAgent"'
```
