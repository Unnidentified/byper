# Installation

Two supported paths: the guided PKG (recommended for any Mac that isn't the development machine) and install.sh from a source checkout. Target: Apple Silicon, macOS 11 Big Sur or newer. (Intel is not built; the target triple is `arm64-apple-macos11.0` — a universal2 build would be needed.)

## Option A — PKG installer (recommended)

1. Get `byper-installer.pkg` (build it: `make app && ./pkg/build_pkg.sh`; published on Releases as `byper-installer-sip.pkg`).
2. Open it. The Installation Type pane offers:
   - **Upgrade / clean reinstall** — replaces the app, keeps your settings.
   - **Uninstall** — removes everything including settings (the uninstall choice's postinstall script, `pkg/uninstall-postinstall`, doubles as a complete uninstaller: app, CLI, completions, LaunchDaemons, defaults, caches; the preinstall script is the upgrade path and deliberately keeps settings).
3. First bypass toggle triggers one admin prompt (attributed to byper) that installs the root helper and fixes SUID ownership.

The postinstall also enables **DevToolsSecurity** and adds you to the **_developer** group — required for the lldb attach path to work on a fresh machine.

## Option B — install.sh from source

```bash
git clone <this repo>
cd byper
make app           # builds bin/byper and byper.app
sudo ./install.sh
```

Installs to:

| Path | What |
|---|---|
| `/usr/local/bin/byper` | SUID-root CLI (`chown root:wheel`, `chmod 4755`) |
| `/usr/local/bin/byp`, `/usr/local/bin/chbypass` | symlinks to the same binary |
| `/usr/local/bin/byper-mon.command` (+ `byp-mon.command`) | standalone monitor |
| `/usr/local/share/zsh/site-functions/_byper`, `_byp` | Zsh completions |
| `/usr/local/share/bash-completion/completions/byper`, `byp` | Bash completions |
| `/Applications/byper.app` | menu bar app |

`install.sh` builds as the invoking user even when run with sudo, so build artifacts never end up root-owned.

### The SUID requirement

`byper` must be `-rwsr-xr-x root:wheel`. A non-SUID copy will *print* `enabled [✓]` while the privileged write silently fails — bypass appears to enable but nothing changes. Verify with:

```bash
ls -la /usr/local/bin/byper /Applications/byper.app/Contents/Resources/byper
```

If you ever copy the app by hand, re-apply:

```bash
sudo chown root:wheel /Applications/byper.app/Contents/Resources/byper
sudo chmod 4755      /Applications/byper.app/Contents/Resources/byper
```

## First run

- Bypass is **OFF** after install; normal charging is untouched until you engage it.
- First bypass toggle needs Command Line Tools (`lldb`). If missing, the tool triggers the install automatically (accept the softwareupdate prompt), or install via `xcode-select --install`.
- Launch `byper.app`; it takes over the status-bar battery icon and asks to replace setup defaults as needed.

## Uninstalling

- Run the PKG and choose **Uninstall** (its postinstall removes every trace, including settings), or
- manually: remove the paths in the table above, `defaults delete com.gefaass.byper`, and clear `~/Library/{Preferences/com.gefaass.byper.plist, Caches/com.gefaass.byper, Saved Application State/com.gefaass.byper.savedState}`.

## Verifying the install works

```bash
byper s          # status line should print real battery data
byper on         # state → ON HOLD (BYPASS); battery flow ≈ 0 mA
byper p          # power rails populate
byper off        # charging resumes
```

If `byper on` says enabled but flow doesn't drop, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
