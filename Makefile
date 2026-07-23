APP     := Chestnut
VERSION := 0.2.1
CONFIG  ?= debug
BUILD   := .build
BUNDLE  := $(BUILD)/$(APP).app
DMG     := $(BUILD)/$(APP).dmg

.PHONY: build bundle run check clean dmg icon site site-gen release-check

SITE_GEN := $(BUILD)/generate-web-sprites

# Runtime checks in lieu of a test target (Command Line Tools ship no
# XCTest — see CONTRIBUTING.md). Compiles the check harness against the
# sources it exercises and runs it.
check: site-gen
	mkdir -p $(BUILD)
	swiftc -parse-as-library -o $(BUILD)/chestnut-check Checks/main.swift \
		Sources/$(APP)/Vaults/VaultRegistry.swift \
		Sources/$(APP)/Vaults/VaultWatcher.swift \
		Sources/$(APP)/Actions/ObsidianBridge.swift \
		Sources/$(APP)/Actions/Courier.swift \
		Sources/$(APP)/Actions/Capture.swift \
		Sources/$(APP)/Support/Journal.swift \
		Sources/$(APP)/Support/Config.swift \
		Sources/$(APP)/Support/DebugLog.swift \
		Sources/$(APP)/Support/ObsidianCLI.swift \
		Sources/$(APP)/Support/Hotkeys.swift \
		Sources/$(APP)/Pet/PetFrames.swift \
		Sources/$(APP)/Pet/SpriteTheme.swift \
		Sources/$(APP)/Plugins/PluginManifest.swift \
		Sources/$(APP)/Plugins/PluginRegistry.swift \
		Sources/$(APP)/Plugins/PluginRunner.swift \
		Sources/$(APP)/Plugins/PluginDispatch.swift
	$(BUILD)/chestnut-check
	@$(SITE_GEN) $(BUILD)/sprites-drift.js $(VERSION)
	@diff -u docs/sprites.js $(BUILD)/sprites-drift.js \
		|| { echo "docs/sprites.js is stale — run 'make site'"; exit 1; }
	@diff -u docs/favicon.svg $(BUILD)/favicon.svg \
		|| { echo "docs/favicon.svg is stale — run 'make site'"; exit 1; }

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(CONFIG)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" \
		$(BUNDLE)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(shell git rev-list --count HEAD)" \
		$(BUNDLE)/Contents/Info.plist
	@test -f Resources/AppIcon.icns && \
		cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns || true
	codesign --force --sign - $(BUNDLE)

run: bundle
	open $(BUNDLE)

# Compile the web-sprite exporter (shared by `site` and the drift check in
# `check`).
site-gen:
	mkdir -p $(BUILD)
	swiftc -parse-as-library -o $(SITE_GEN) Scripts/generate-web-sprites.swift \
		Sources/$(APP)/Pet/PetFrames.swift \
		Sources/$(APP)/Pet/SpriteTheme.swift \
		Sources/$(APP)/Support/Config.swift

# Regenerate the website's sprite data from the app's frame/theme sources.
site: site-gen
	$(SITE_GEN) docs/sprites.js $(VERSION)

icon:
	mkdir -p $(BUILD)
	swiftc -parse-as-library -o $(BUILD)/generate-icon Scripts/generate-icon.swift \
		Sources/$(APP)/Pet/PetFrames.swift \
		Sources/$(APP)/Pet/SpriteTheme.swift \
		Sources/$(APP)/Support/Config.swift
	$(BUILD)/generate-icon
	iconutil -c icns -o Resources/AppIcon.icns $(BUILD)/$(APP).iconset
	rm -rf $(BUILD)/$(APP).iconset $(BUILD)/generate-icon

dmg: CONFIG := release
dmg: bundle
	rm -f $(DMG)
	mkdir -p $(BUILD)/dmg-stage
	cp -R $(BUNDLE) $(BUILD)/dmg-stage/
	ln -sf /Applications $(BUILD)/dmg-stage/Applications
	hdiutil create -volname $(APP) -srcfolder $(BUILD)/dmg-stage \
		-ov -format UDZO $(DMG)
	rm -rf $(BUILD)/dmg-stage

clean:
	swift package clean
	rm -rf $(BUNDLE) $(DMG)

# Release preflight: everything verifiable before the smoke test and the
# public steps (tag/push/publish — see RELEASING.md). Cheap guards first,
# then checks, then the release DMG. Prints the sha256 the cask needs.
release-check:
	@git diff --quiet && git diff --cached --quiet \
		|| { echo "FAIL: working tree not clean"; exit 1; }
	@test "$$(git branch --show-current)" = "main" \
		|| { echo "FAIL: not on main"; exit 1; }
	@! git rev-parse -q --verify "v$(VERSION)" >/dev/null \
		|| { echo "FAIL: v$(VERSION) already tagged"; exit 1; }
	@grep -q "^## \[$(VERSION)\] — 20" CHANGELOG.md \
		|| { echo "FAIL: CHANGELOG.md has no dated [$(VERSION)] section"; exit 1; }
	$(MAKE) check
	$(MAKE) dmg
	@test "$$(plutil -extract CFBundleShortVersionString raw \
		$(BUNDLE)/Contents/Info.plist)" = "$(VERSION)" \
		|| { echo "FAIL: bundle stamps $$(plutil -extract CFBundleShortVersionString raw $(BUNDLE)/Contents/Info.plist), not $(VERSION)"; exit 1; }
	@echo "sha256 for the Homebrew cask:"
	@shasum -a 256 $(DMG)
	@echo "OK — smoke test the app, then RELEASING.md from 'Merge and tag'."
