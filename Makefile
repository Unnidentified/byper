# ============================================================
#  byper Makefile
#  Compiles CLI binary 'byper' & Native GUI 'byper.app'
#  Feature set: bypass charge, powersave, caffeinate, settings.
# ============================================================

CC = clang
CFLAGS = -O3 -Wall -Wextra -std=c11 -fobjc-arc -target arm64-apple-macos11.0
FRAMEWORKS = -framework IOKit -framework CoreFoundation -framework Foundation

# Version: CFBundleShortVersionString in src/app/Info.plist is the single source
# of truth. BYPER_VERSION overrides it, the same way pkg/build_pkg.sh does.
BYPER_VERSION ?= $(shell plutil -extract CFBundleShortVersionString raw -o - src/app/Info.plist 2>/dev/null || echo 0.0.0-dev)
VERSION_DEFINE = -DBYPER_VERSION=\"$(BYPER_VERSION)\"

SWIFTC = swiftc
SWIFT_FLAGS = -O -whole-module-optimization -target arm64-apple-macos11.0
SWIFT_FRAMEWORKS = -framework AppKit -framework SwiftUI -framework Foundation -framework IOKit -framework Carbon -framework AppIntents

SRC = src/main.c src/smc.c src/battery.c src/power.c src/powerui.m
TARGET_DIR = bin
TARGET = $(TARGET_DIR)/byper
MON_CMD = $(TARGET_DIR)/byper-mon.command

APP_NAME = byper.app
APP_DIR = $(APP_NAME)/Contents
APP_BIN = $(APP_DIR)/MacOS/byper
APP_RES = $(APP_DIR)/Resources
HELPER_SRC = src/app/install_helper.c
HELPER_BIN = $(APP_RES)/byper-installer
SWIFT_SRC = src/app/BatteryPillIcon.swift src/app/GlassPopover.swift src/app/PopoverTuning+Outline.swift src/app/PopoverTuning+Depth.swift src/app/PopoverTuning+TopBar.swift src/app/BatteryMonitor.swift src/app/BatteryDropdownView.swift src/app/CLIEngineBridge.swift src/app/AppDelegate.swift src/app/ByperIntents.swift

all: $(TARGET) $(MON_CMD) app

$(TARGET): $(SRC) src/app/Info.plist
	@mkdir -p $(TARGET_DIR)
	$(CC) $(CFLAGS) $(VERSION_DEFINE) $(SRC) $(FRAMEWORKS) -o $(TARGET)
	@codesign -s - -f $(TARGET) >/dev/null 2>&1 || true
	@echo "Build successful: $(TARGET)"

$(MON_CMD): src/byp-mon.command
	@mkdir -p $(TARGET_DIR)
	@cp -f src/byp-mon.command $(MON_CMD)
	@chmod +x $(MON_CMD)

app: $(TARGET) $(APP_BIN)

$(APP_BIN): $(SWIFT_SRC) src/app/Info.plist $(TARGET)
	@mkdir -p $(APP_DIR)/MacOS $(APP_RES)
	@cp -f src/app/Info.plist $(APP_DIR)/Info.plist
	@cp -f src/app/AppIcon.icns $(APP_RES)/AppIcon.icns
	@cp -f $(TARGET) $(APP_RES)/byper
	$(CC) $(CFLAGS) $(HELPER_SRC) -o $(HELPER_BIN)
	@mkdir -p $(APP_RES)/fonts
	@cp -f src/app/fonts/*.ttf $(APP_RES)/fonts/
	$(SWIFTC) $(SWIFT_FLAGS) $(SWIFT_FRAMEWORKS) $(SWIFT_SRC) -o $(APP_BIN)
	@codesign -s - -f $(APP_NAME) >/dev/null 2>&1 || true
	@echo "App bundle assembled: $(APP_NAME)"

clean:
	rm -rf $(TARGET_DIR) $(APP_NAME) byp.app

install: all
	@echo "[*] Installing CLI tools to /usr/local/bin..."
	@sudo mkdir -p /usr/local/bin
	@sudo cp -f $(TARGET) /usr/local/bin/byper
	@sudo chown root:wheel /usr/local/bin/byper
	@sudo chmod 4755 /usr/local/bin/byper
	@sudo codesign -s - -f /usr/local/bin/byper >/dev/null 2>&1 || true
	@sudo ln -sf /usr/local/bin/byper /usr/local/bin/byp
	@sudo ln -sf /usr/local/bin/byper /usr/local/bin/chbypass
	@sudo cp -f $(MON_CMD) /usr/local/bin/byper-mon.command
	@sudo chmod 755 /usr/local/bin/byper-mon.command
	@sudo ln -sf /usr/local/bin/byper-mon.command /usr/local/bin/byp-mon.command
	@echo "[*] Installing byper.app to /Applications..."
	@pkill -f "/Applications/byper.app" 2>/dev/null || true
	@sudo rm -rf /Applications/byp.app /Applications/byper.app
	@sudo cp -R $(APP_NAME) /Applications/byper.app
	@sudo chown -R root:wheel /Applications/byper.app
	@sudo chmod 4755 /Applications/byper.app/Contents/Resources/byper
	@echo "[*] Launching /Applications/byper.app..."
	@open /Applications/byper.app
	@/usr/local/bin/byper lpm 0 >/dev/null 2>&1 || true
	@echo "[OK] Installed successfully. CLI available as 'byper' or 'byp', and GUI app running from /Applications/byper.app."

uninstall:
	@echo "[*] Removing from /usr/local/bin and /Applications..."
	@sudo rm -f /usr/local/bin/byper /usr/local/bin/chbypass /usr/local/bin/byp /usr/local/bin/byper-mon.command /usr/local/bin/byp-mon.command /tmp/byp.state
	@sudo rm -f /usr/local/share/zsh/site-functions/_byper /usr/local/share/zsh/site-functions/_byp /usr/local/share/bash-completion/completions/byper /usr/local/share/bash-completion/completions/byp
	@sudo rm -rf /Applications/byp.app /Applications/byper.app
	@echo "[OK] Uninstalled."

pkg: app
	@chmod +x pkg/build_pkg.sh
	@./pkg/build_pkg.sh

pkg-test: app
	@chmod +x pkg/build_pkg.sh
	@./pkg/build_pkg.sh test

test-pkg: pkg-test

.PHONY: all clean install uninstall app pkg pkg-test test-pkg
