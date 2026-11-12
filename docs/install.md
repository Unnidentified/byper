# Install

## Requirements

- Apple Silicon Mac (M1 or newer). The build target is `arm64-apple-macos11.0`.
- macOS 11 Big Sur or newer. The Liquid Glass popover needs macOS 26; older
  systems get the previous dark solid shell, and everything else works the same.
- Command Line Tools, for `lldb`. The package installs them if they are missing.
- SIP's debug restriction relaxed. See [limitations.md](limitations.md#sip).

## From the package

Download `byper-installer-<version>.pkg` or `.dmg` from [Releases](https://github.com/Unnidentified/byper/releases/latest).

The package offers two choices:

- **Install** replaces the app and the CLI, keeps your settings.
- **Uninstall** removes the app, the CLI, the completions and the settings.

The postinstall copies the CLI to `/usr/local/bin/byper`, sets `root:wheel` and `4755`, installs the completions, enables `DevToolsSecurity`, adds the console user to `_developer`, and opens the app.

If Gatekeeper blocks the app:

```bash
xattr -cr /Applications/byper.app
```

## From Homebrew

The cask lives in this repository, so tap it by URL:

```bash
brew tap Unnidentified/byper https://github.com/Unnidentified/byper
brew install --cask byper
```

Upgrade and uninstall:

```bash
brew upgrade --cask byper
brew uninstall --cask byper
```

The cask runs the same `.pkg`, so the postinstall still copies the CLI to `/usr/local/bin/byper`, sets `root:wheel` and `4755`, installs the completions and opens the app. `brew uninstall` releases any active hold, clears Low Power Mode, clears the lid sleep switch, and removes the CLI, the symlinks, the completions and the app. Add `--zap` to remove the settings too.

## From source

```bash
git clone https://github.com/Unnidentified/byper.git
cd byper
make all
sudo ./install.sh
```

`install.sh` builds as the invoking user even when run with sudo, so the build artifacts do not end up root-owned. It installs the same paths as the package, plus the standalone monitor.

## The SUID bit

`byper` must be `-rwsr-xr-x root:wheel`. A non-SUID copy cannot attach to `PowerUIAgent`, so `byper on` prints `[FAIL] bypass hold not confirmed` and exits 1. Check both copies:

```bash
ls -la /usr/local/bin/byper /Applications/byper.app/Contents/Resources/byper
```

If the bit is missing:

```bash
sudo chown root:wheel /usr/local/bin/byper /Applications/byper.app/Contents/Resources/byper
sudo chmod 4755 /usr/local/bin/byper /Applications/byper.app/Contents/Resources/byper
```

## First run

Bypass is off after install. The app takes over the status bar battery icon. The first bypass toggle may ask for an admin password to repair the helper.

Verify the install:

```bash
byper s          # real battery data
byper on         # state: hold, flow near 0 mA
byper p          # rails populate
byper off        # charging resumes
```

## Uninstall

Run the package and choose **Uninstall**. It releases any active hold, clears Low Power Mode, clears the lid sleep switch, removes the binaries, the app, the completions and the settings. The uninstall component runs as root with no `SUDO_USER`, so the CLI resolves the settings owner to the console user and clears the flag from that user's domain before it deletes itself.

The source `uninstall.sh` performs the same hardware reset before it removes anything: it releases any active hold and clears Low Power Mode, so the machine returns to stock power behaviour. It calls `sudo pmset -a lowpowermode 0` directly, so expect a password prompt.
