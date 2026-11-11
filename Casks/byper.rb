cask "byper" do
  version "3.1.0"
  sha256 "2c8c0d3ffd0256ce619a27d02ac06666faea68142c3968307a9edaaaf00144d1"

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

                # The pkg postinstall creates the CLI, its symlinks and the
                # completions outside the Caskroom, so Homebrew has no artifact
                # for them. Remove them here. Each removal is best effort: the
                # check at the end decides whether the uninstall succeeded.
                paths=(
                  /usr/local/bin/byper
                  /usr/local/bin/byp
                  /usr/local/bin/chbypass
                  /usr/local/share/zsh/site-functions/_byper
                  /usr/local/share/zsh/site-functions/_byp
                  /usr/local/share/bash-completion/completions/byper
                  /usr/local/share/bash-completion/completions/byp
                  /Applications/byper.app
                  /tmp/byp.state
                  /tmp/byp_lldb.lock
                  /tmp/byp_lldb_worker.log
                )
                for path in "${paths[@]}"; do
                  /bin/rm -rf "$path" || true
                done
                /bin/rm -f /tmp/byp_cmd_*.lldb || true

                # A partial removal must not look like success. Name every path
                # that survived so the user can finish the job by hand.
                left=""
                for path in "${paths[@]}"; do
                  if [ -e "$path" ] || [ -L "$path" ]; then
                    left="$left $path"
                  fi
                done
                for path in /tmp/byp_cmd_*.lldb; do
                  if [ -e "$path" ] || [ -L "$path" ]; then
                    left="$left $path"
                  fi
                done
                if [ -n "$left" ]; then
                  echo "byper uninstall incomplete. These paths are still present:" >&2
                  for path in $left; do
                    echo "  $path" >&2
                  done
                  echo "Remove them with: sudo rm -rf$left" >&2
                  echo "Then run: brew uninstall --cask byper" >&2
                  exit 1
                fi
              EOS
              sudo:         true,
              must_succeed: true,
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
