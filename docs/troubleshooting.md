# Troubleshooting

## Bypass says enabled but the battery still charges

The SUID bit is missing or the binary is not root-owned. The failure is silent: the CLI prints `enabled [✓]` and the hardware does nothing.

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

## Popover does not resize

Every expandable flag must be in the `Publishers.Merge` in `AppDelegate.applicationDidFinishLaunching`. On macOS 13+ the hosting controller's `preferredContentSize` handles it, but the merge still drives the older path.

## Timers stall with a menu open or the screen asleep

Timers must be added to `RunLoop.main` in `.common` mode. `Timer.scheduledTimer` uses `.default` and stalls while a menu tracks the cursor.

## Diagnostics

```bash
byper s                      # CLI alive and reading hardware
ls -la /usr/local/bin/byper  # SUID intact
pgrep -fl PowerUIAgent       # daemon running
pgrep -fl lldb               # worker stuck (should be transient)
BYP_LLDB_DEBUG=1 byper on    # verbose attach log
log show --last 5m --predicate 'process == "PowerUIAgent"'
```
