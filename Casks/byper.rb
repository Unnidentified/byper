cask "byper" do
  version "3.0.1"
  sha256 "2a2d4688d1de272458ea161c1016a9f2ff01fd63c50e1244844d20468c2c903d"

  url "https://github.com/Unnidentified/byper/releases/download/v#{version}/byper-installer-#{version}.pkg"
  name "byper"
  desc "Charge bypass and battery toolkit for Apple Silicon Macs"
  homepage "https://byper.org/"

  depends_on arch: :arm64
  depends_on macos: :big_sur

  pkg "byper-installer-#{version}.pkg"

  uninstall early_script: {
              executable:   "/bin/bash",
              args:         ["-c", <<~EOS],
                # Release any active hold and clear Low Power Mode while the CLI
                # still exists, so the machine returns to stock charging.
                if [ -x /usr/local/bin/byper ]; then
                  /usr/local/bin/byper off >/dev/null 2>&1 || true
                  /usr/local/bin/byper lpm off >/dev/null 2>&1 || true
                fi
                /usr/bin/pmset -a lowpowermode 0 >/dev/null 2>&1 || true
                sleep 1

                /usr/bin/pkill -f "byper.app/Contents/MacOS/byper" >/dev/null 2>&1 || true

                # The CLI and its symlinks are root-owned, so the delete
                # directive skips them: it refuses any path whose parent
                # directory is not writable by the user. Remove them here.
                /bin/rm -f /usr/local/bin/byper /usr/local/bin/byp /usr/local/bin/chbypass
                /bin/rm -f /usr/local/share/zsh/site-functions/_byper /usr/local/share/zsh/site-functions/_byp
                /bin/rm -f /usr/local/share/bash-completion/completions/byper /usr/local/share/bash-completion/completions/byp
                /bin/rm -rf /Applications/byper.app
                /bin/rm -f /tmp/byp.state /tmp/byp_lldb.lock /tmp/byp_lldb_worker.log
                /bin/rm -f /tmp/byp_cmd_*.lldb
              EOS
              sudo:         true,
              must_succeed: false,
            },
            pkgutil:      [
              "com.gefaass.byper",
              "com.gefaass.byper.uninstall",
            ],
            delete:       "/Applications/byper.app"

  zap trash: [
    "~/Library/Caches/com.gefaass.byper",
    "~/Library/HTTPStorages/com.gefaass.byper",
    "~/Library/Preferences/com.gefaass.byper.plist",
    "~/Library/Saved Application State/com.gefaass.byper.savedState",
  ]

  caveats <<~EOS
    byper needs SIP's debug restriction relaxed. Boot into Recovery, open
    Terminal and run:

      csrutil enable --without debug

    Without it, "byper on" fails with "Not allowed to attach" and bypass
    cannot work on that machine.

    The installer copies the CLI to /usr/local/bin/byper and sets it to
    root:wheel with mode 4755. The SUID bit is required: a copy without it
    cannot attach to PowerUIAgent.
  EOS
end
