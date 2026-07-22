# Chestnut — partner for Obsidian

Native macOS desktop companion for multi-vault Obsidian users. An always-on-top
pixel-art treasure-chest creature ("Chestnut") that reacts to writing activity
and acts as a control surface across vaults. Shipped as v0.1.0 — free app with
a Ko-fi tip jar, no license mechanism, no paywall, no network calls.

## Build & run

CLI-first: SPM + Makefile. No Xcode project — don't generate one.

```bash
make build    # swift build (CONFIG=debug|release)
make bundle   # build -> .build/Chestnut.app (Info.plist + ad-hoc codesign)
make run      # bundle + open the .app
make dmg      # release build -> .build/Chestnut.dmg (drag-to-Applications)
make icon     # regenerate Resources/AppIcon.icns from sprite data
make site     # regenerate docs/sprites.js + favicons from Swift sources
make check    # runtime checks (Checks/main.swift) — run before committing
make clean
pkill -x Chestnut  # quit the app (no Dock icon; use right-click menu)
```

**Testing:** this machine has Command Line Tools only (no Xcode) — no XCTest
or Swift Testing. `make check` compiles `Checks/main.swift` directly against
source files and runs assertions (registry parsing, FSEvents, URL building,
courier traversal, sprite drift checks, etc.). Extend it when adding testable
logic. In-app invariants stay as runtime `precondition`s.

**Bash output truncation:** the harness silently truncates long stdout. Never
rely on seeing full output. Always pipe through `tail -n N` or `grep` to
extract what matters. For `make check`:

```bash
make check 2>&1 | grep -E "FAIL|ALL CHECKS|FAILED"; echo "exit: $?"
```

- Swift 6 language mode, strict concurrency. UI types are `@MainActor`.
- Min deployment target: macOS 14.
- `LSUIElement` app — no Dock icon, no main menu.
- Version source of truth: `VERSION` in Makefile, stamped into bundle plist.

## Source layout

```
Sources/Chestnut/
  main.swift              # entry point
  AppDelegate.swift       # app lifecycle, menu, panel coordination

  Pet/                    # SpriteKit rendering + state machine
    PetWindow.swift       # NSWindow host, right-click menu, drag-drop
    PetScene.swift        # SKScene, state-driven animation, fps management
    PetController.swift   # pure state machine (idle/writing/delivery)
    PetFrames.swift       # hand-coded pixel frame matrices
    Sprites.swift         # frame -> SKTexture pipeline (.nearest filtering)
    SpriteTheme.swift     # color palettes (built-in + user custom themes)

  Vaults/                 # vault discovery + filesystem observation
    VaultRegistry.swift   # parses obsidian.json, keyed by path (never name)
    VaultWatcher.swift    # FSEvents per-vault file watcher

  Actions/                # user-initiated operations
    ObsidianBridge.swift  # obsidian:// URLs, CLI eval, vault/note/file opening
    Courier.swift         # note delivery across vaults (move/copy + attachments)
    Capture.swift         # quick-capture to daily note or inbox

  Panels/                 # SwiftUI palettes hosted in NSPanel
    VaultPalette.swift    # vault hopper + courier destination picker
    CapturePanel.swift    # quick-capture editor with formatting toolbar
    NoticePanel.swift     # speech-bubble feedback (anchored to sprite)
    PetPanel.swift        # shared panel hosting utilities

  Plugins/                # user-extensible shell-script plugins
    PluginManifest.swift  # manifest.json parsing, PluginEnvelope (api: 1)
    PluginRegistry.swift  # discovery + FSEvents hot-reload of plugins dir
    PluginRunner.swift    # Process execution, timeout, output interpretation
    PluginDispatch.swift  # pasteboard → input type classification
    PluginPalette.swift   # picker UI for multiple matching plugins

  Support/
    Config.swift          # JSON config (~/Library/Application Support/Chestnut/config.json)
    Hotkeys.swift         # global hotkey registration (Carbon)
    Journal.swift         # courier/capture operation journal for undo
    ObsidianCLI.swift     # trusted-path CLI lookup (/opt/homebrew, /usr/local)
    AppInfo.swift         # version, URLs (GitHub releases, Ko-fi, support)

Scripts/                  # code generators (no runtime dependency)
  generate-icon.swift     # sprite -> AppIcon.icns
  generate-web-sprites.swift  # PetFrames + themes -> docs/sprites.js

Resources/
  Info.plist, AppIcon.icns

Checks/
  main.swift              # runtime test assertions (make check)
```

## Architecture

- **Layer split:** AppKit = thin window/host; SpriteKit = pet rendering;
  SwiftUI = panels. Panels are NSPanel-hosted, never take key focus from
  other apps.
- **Sprites** are hand-coded string matrices mapped through palette colors to
  `SKTexture` with `.nearest` filtering. No image assets, no art tools.
- **State machine** (`PetController`) is pure — idle, writing, delivery states
  drive animation in `PetScene`. Writing state detected via `VaultWatcher`
  FSEvents.
- **FPS management:** 10fps steady-state, 60fps only during hop/gulp gestures.
  Idle CPU ~2%.
- **Config** persists to `~/Library/Application Support/Chestnut/config.json`.
  Unparseable config preserved to `.bak` before defaults load.
  `noticeDuration` (seconds, floor 1) controls how long notice bubbles stay.
- **Hotkeys:** ⌃⌥Space (capture), ⌃⌥V (hopper), ⌃⌥C (paste — plugin dispatch
  from clipboard), ⌃⌥O (notice action — registered only while an actionable
  bubble is visible). All configurable via config.
- **Pinned vault:** one vault sorts first everywhere (hopper, courier, capture).
  Toggled via pin icon or ⌘P.
- **Launch at login:** `SMAppService.mainApp`, toggled in right-click menu.
- **Full-screen visibility:** `collectionBehavior`-based, toggled in menu.
  orderOut/orderFront on toggle to force window-server re-evaluation.
- **`obsidian` CLI** is an optional enhancement — every CLI call has a direct-FS
  fallback. Trusted path lookup only (never `$PATH`).
- **Plugin system** (api: 1): shell scripts in `~/.config/chestnut/plugins/<name>/`
  with a `manifest.json` declaring accepted pasteboard types and output mode.
  Plugins receive input via env vars + stdin, produce output on stdout. Output
  modes: capture (pre-fill), save (to vault), clipboard, notify, or structured
  JSON envelope for runtime control. Structured envelope supports `attachments`
  array for saving additional files (images, PDFs) alongside a note. Scripts are
  exec'd directly (shebang), configurable timeout (default 10s). Hot-reloaded via
  FSEvents. Installed plugins listed in right-click menu → Plugins submenu (with
  "Open Plugins Folder"); individual plugins can be enabled/disabled from the
  submenu (persisted in `config.json` as `disabledPlugins`). Manifests support an
  optional `extensions` array (e.g. `["txt", "csv"]`) to narrow file-type matching
  within a broad `accepts` category — unmatched files fall through to the courier.
  Folder drops route to a `folder` plugin when one exists; otherwise the courier
  handles them (copies/moves the directory as-is). Non-.md file drops route to a
  matching plugin when one exists; .md drops always go to courier. Zero-cost when
  no plugins installed — courier and all existing features work identically.
- **Vault containment** is enforced by `Courier.isContained(_:inVault:)` — a
  shared helper used by courier, capture, plugin save, and obsidian:// URL
  resolution. Checks standardized-path prefix (with trailing `/`) and rejects
  `.obsidian` path components.

## Hard invariants

- **Never modify Obsidian's files or settings.** Read-only observation of
  `obsidian.json`, vault dirs, `.obsidian/*.json`. Writes only as explicit
  user-initiated actions (courier move, capture append), never to `.obsidian/`.
- **Key vaults by path, never by name** (names collide). `obsidian://open?path=...`
  throughout.
- **No network calls, no telemetry.** "Check for Updates" opens the GitHub
  releases page in a browser.
- **Courier never overwrites:** name conflicts get Obsidian-style suffixes;
  every operation is journaled for undo.
- **Vault containment:** courier and capture refuse paths resolving outside the
  vault root (standardized-path `hasPrefix`).
- **No reuse of Obsidian's gem logo;** "for Obsidian" nominative phrasing only.
- **Cross-Vault Search is permanently out of scope** — decided early, won't build it.

## Website

Landing page at `gapmiss.github.io/chestnut` — hand-written HTML/CSS/JS in `docs/`,
deployed via GitHub Pages (main branch, docs folder). No build step, no image assets.

The hero chestnut is a `<canvas>` driven by the app's real frame data exported to
`docs/sprites.js` via `make site`. `make check` fails if sprites.js drifts from
Swift sources. The web pet mirrors PetScene states/timings and includes interactive
demos of Vault Hopper, Quick Capture, Note Courier (drag-drop), and the right-click
menu — all labeled as demos.

Key site details:
- Light/dark toggle (top-right), persisted in localStorage, inline head script
  prevents flash. Sprite theme follows site mode (Sunbleached/Obsidian Night)
  until user picks one in the menu.
- Download button targets `releases/latest/download/Chestnut.dmg`.
- Naming: the pet is "Chestnut" in copy, never "the chestnut". When a generic
  noun is needed: "a pixel-art treasure chest creature".
- Demos will drift if the real panels or menu change — reminder comments sit in
  the relevant Swift source files.

## Not notarized

Users clear Gatekeeper via right-click -> Open (pre-macOS 15) or System Settings ->
"Open Anyway" (macOS 15+), or `xattr -dr com.apple.quarantine`. Notarization is
undecided.
