# Troubleshooting

## Bypass will not engage

The SUID bit is missing or the binary is not root-owned. Without it the CLI cannot attach to `PowerUIAgent`, so `byper on` prints `[FAIL] bypass hold not confirmed` and exits 1.

```bash
ls -la /usr/local/bin/byper /Applications/byper.app/Contents/Resources/byper
# must show: -rwsr-xr-x  root:wheel
```

Fix it with the package, the in-app admin prompt, or by hand:

```bash
sudo chown root:wheel /usr/local/bin/byper /Applications/byper.app/Contents/Resources/byper
sudo chmod 4755 /usr/local/bin/byper /Applications/byper.app/Contents/Resources/byper
```

## lldb attach fails

The bypass needs root attach to `PowerUIAgent`, which macOS gates behind developer-tool policy.

1. Enable developer tools:
   ```bash
   sudo DevToolsSecurity -enable
   sudo dseditgroup -o edit -a "$USER" -t user _developer
   ```
2. Install the Command Line Tools:
   ```bash
   xcode-select --install
   ```
3. If the attach is still refused, SIP is blocking it. Relax the debug restriction once in Recovery:
   ```bash
   csrutil enable --without debug
   ```
   See [limitations.md](limitations.md#sip).

For a verbose attach log:

```bash
BYP_LLDB_DEBUG=1 byper on
cat /tmp/byp_lldb_debug.log
```

## Toggle hangs or does nothing for 30 to 60 seconds

Two causes:

- The apply is asynchronous. The lldb worker runs detached and the verify poll can take up to 45s. Wait for the state to flip instead of toggling again.
- `PowerUIAgent` debounces rapid opposite commands. Off then on within seconds can be swallowed or land late. This is OS behaviour.

## Lid close still sleeps the machine

"On lid close" is the one caffeinate condition that needs a privileged switch.
The idle-sleep assertions do not survive a lid close, so byper sets
`SleepDisabled` through the SUID CLI. Check what the machine actually reports:

```bash
byper lid status
pmset -g | grep SleepDisabled
```

`SleepDisabled 1` means the switch is set. `SleepDisabled 0` with the condition
armed means it did not land, and the app marks the row: a red `!` beside
`On lid close` and `lid!` in the row summary. The usual cause is a CLI that is
not SUID root, so `pmset` refuses and exits 0 anyway:

```bash
ls -la /usr/local/bin/byper
# must show: -rwsr-xr-x  root:wheel
```

Fix it with the package, the in-app admin prompt, or by hand:

```bash
sudo chown root:wheel /usr/local/bin/byper
sudo chmod 4755 /usr/local/bin/byper
```

The switch is global and it is not owned by a process, so it stays set if byper
is killed. byper clears it on disarm, on quit and on the next launch. To clear it
by hand:

```bash
sudo pmset -a disablesleep 0
```

## Bypass re-engages by itself

An automation re-engaged it. Check the Settings row: Auto Bypass on Connect, at Login, or on Display. The app also reseeds a hold that was active at quit, so a previous session can come back on its own.

## App is damaged after a download

Quarantine on an ad-hoc signed app. Use System Settings, Privacy and Security, Open Anyway, or:

```bash
xattr -dr com.apple.quarantine /Applications/byper.app
```

## Build fails with "can't write output file"

Root-owned build artifacts from an earlier sudo build. `install.sh` builds as the invoking user to prevent this. If it already happened:

```bash
sudo chown -R "$USER" bin byper.app
make clean && make all
```

## Popover does not resize when a row expands

The panel is a fixed-width `NSPanel` that refits its height on demand. Every
expandable flag must be in the `Publishers.Merge4` chain in
`AppDelegate.applicationDidFinishLaunching`, which calls `popoverPanel.refit()`.
A new expandable row that is not in that chain will open and stay clipped.

`refit()` is called three times per change, at 0, 50ms and 300ms, because
SwiftUI commits the layout after the publisher fires. Do not remove the delayed
calls to "clean it up".

## Timers stall with a menu open or the screen asleep

Timers must be added to `RunLoop.main` in `.common` mode. `Timer.scheduledTimer`
uses `.default` and stalls while a menu tracks the cursor.

## A hard rectangle surrounds the popover

The window shadow. AppKit derives it from the window's alpha channel, and a
partly transparent glass shell makes it fall back to a rectangular mask, which
paints a square behind the rounded corners. `invalidateShadow()` does not fix
it. `PopoverPanel` sets `hasShadow = false` for this reason. If the rectangle
comes back, something re-enabled the shadow or added a background to the hosting
view.

## The glass looks like flat grey plastic

`PopoverTuning.shellStyle` is `.clear`, which is a brown tint at 0.20. On a very
light wallpaper that can read as grey. Switch to `.dark` for a 0.45 tint, which
keeps the old dark look. Both presets have to hold up under System Settings,
Appearance, Liquid Glass, in both Clear and Tinted.

## The menu bar icon does not follow the wallpaper

The signal is the status item button's `effectiveAppearance`, filtered to
`.vibrantDark` and `.vibrantLight`. `NSApp.effectiveAppearance` follows the
system light and dark mode, not the menu bar, so it is the wrong signal.
`NSWorkspace.desktopImageDidChangeNotification` does not exist in this SDK.

## Diagnostics

```bash
byper s                      # CLI alive and reading hardware
ls -la /usr/local/bin/byper  # SUID intact
pgrep -fl PowerUIAgent       # daemon running
pgrep -fl lldb               # worker stuck (should be transient)
BYP_LLDB_DEBUG=1 byper on    # verbose attach log
log show --last 5m --predicate 'process == "PowerUIAgent"'
```
