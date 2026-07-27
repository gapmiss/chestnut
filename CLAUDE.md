# Chestnut — partner for Obsidian

Native macOS desktop companion for Obsidian users (one vault or many). An always-on-top
pixel-art treasure-chest creature ("Chestnut") that reacts to writing activity
and acts as a control surface across vaults. Free app funded by GitHub Sponsors,
no license mechanism, no paywall, no network calls. Current release is `VERSION`
in the Makefile (0.5.0), shipped as a DMG and a Homebrew cask
(`gapmiss/tap/chestnut`, a separate repo — see RELEASING.md).

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
    PetGeometry.swift     # window size/origin maths, screens injected (testable)
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
    AppInfo.swift         # version, URLs (GitHub releases, GitHub Sponsors)

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
  Idle CPU ~3% of one core (measured on 0.5.0 by sampling `ps -o cputime` over
  a 30s and a 45s idle window: 3.8% and 2.4%; `ps -o %cpu` reports a
  since-launch average, ~2.5%, and is the wrong number to quote).
- **Reduce Motion** is honored, and it is the *effect* that is conditional, not
  the frame rate. `PetScene.setMotionFrozen` stops everything that moves or
  scales — breathing (which otherwise runs in every state, forever), the sleep
  z-drift, the click hop, and the gulp's squash — while leaving the texture
  swaps running, so the eye peek, the writing chatter and the chew loop still
  say which state the pet is in. The rate stays at `FrameRate.calm`: those
  swaps run as fast as 0.2s a frame, so dropping it would turn them into a
  stutter. Stillness is what this buys; battery is not. The effective value is
  `AppState.motionFrozen(app:system:)` — Chestnut's own Settings ▸ Reduce
  Motion **OR** `NSWorkspace.accessibilityDisplayShouldReduceMotion`, so the
  menu can add stillness but never take it away, and the row draws checked and
  disabled while the system asks. Ticking Chestnut's row never writes the
  system setting. `PetWindow` observes
  `accessibilityDisplayOptionsDidChangeNotification` (on
  `NSWorkspace.shared.notificationCenter`, not the default centre) and drops
  the observer in `close()` beside the mouse monitors, since a theme or size
  change rebuilds the window. `docs/chestnut.js` mirrors all of this against
  `prefers-reduced-motion`.
- **Two settings files**, both in `~/Library/Application Support/Chestnut/`:
  `config.json` (`Config`) is user-owned and hand-edited — hotkeys, custom
  themes, capture destination, `debug`. `state.json` (`AppState`) is app-owned
  — window position, size, opacity, theme, copy-on-drop, full-screen,
  `noticeDuration`, `reduceMotion`, pinned vault, last capture vault,
  `disabledPlugins`.
  **The app never writes `config.json`** except `createIfMissing()` on first
  run, which only fires when no file exists. No other write path exists, and
  none should be added; that invariant is what keeps a window drag from
  clobbering a hand-edited hotkey. Anything gaining a UI moves to `AppState`.
- **No settings migrations.** Both decoders are tolerant: unknown and stale
  keys are ignored, missing keys take defaults, so a key can move between the
  files without migration code. Moving one costs the user the value (it
  reverts to default) but never a broken launch. That trade holds because
  everything in `AppState` is a menu click away — reconsider only if a value
  becomes expensive to recreate or its loss would be *invisible*. The 0.3
  split shipped with a migration; it was deleted in 0.4 rather than carried.
  Unparseable files are *moved* to the first free `.bak`/`.bak.N`, never
  copied over an earlier backup. `CGPoint` encodes as `[x, y]`, not `{"x":…}`.
  `noticeDuration` (seconds, clamped to 1–30) is set from the menu and applies
  to the next bubble without a relaunch.
- **Right-click menu** (`PetWindow.showMenu`) is ordered actions first, then
  the pet's identity, then about: Vaults…/Capture… · Undo Last Delivery/Undo
  Last Capture, each carrying the name of the record it reverses as a subtitle
  · Size ▸ / Theme ▸ / Settings ▸ / Plugins ▸ · Check for Updates…
  (version + ↗ in one badge) / Support Chestnut · Quit. Size and Theme stay
  top-level deliberately; everything set-once lives in Settings ▸, which is
  flat: Opacity ▸, Notice Bubble ▸, then Reduce Motion / Copy on Drop / Show in
  Full Screen / Launch at Login, then Reset Position / Edit Configuration…. `showMenu` is an assembly list; one builder method per group.
  **The menu reaches a third level in exactly two places** — Settings ▸
  Opacity ▸ and Settings ▸ Notice Bubble ▸ — and nowhere else. Both were
  sliders; a slider is an `NSMenuItem.view`, and **AppKit skips view items in
  a menu's key loop**, so neither value could be set without a mouse. That
  matters most for opacity: at its floor the sprite is nearly invisible, and
  the only control that restored it was a slider you had to drag on a pet you
  could no longer see. Discrete preset items are keyboard-reachable and are
  one control per value rather than a slider shadowed by a stand-in. **Do not
  reintroduce a view-based row** without solving this. Presets live in
  `AppState`, not `PetWindow`, so `make check` can reach them
  (`PetWindow.swift` is not in the check target); the checkmark is an exact
  match, so a value persisted between stops shows none.
  `showMenuFromHotkey` is the keyboard entry point: it must call
  `NSApp.activate` or menu tracking reads keys from whatever is frontmost, and
  it positions via `menuOrigin`, which flips the menu above the sprite when it
  won't fit below. **The `menu` hotkey is unregistered for as long as the menu
  tracks** (`setMenuHotkeyEnabled`, driven by `onMenuTrackingChange`): Carbon
  captures the keystroke but its nested loop won't dispatch during tracking, so
  a registered key queues every press and replays them the moment Esc
  dismisses the menu, reopening it once per press. The website re-creates this
  menu by hand
  (`docs/chestnut.js`, `renderMenu`) and nothing checks the two agree — change
  them together.
- **Hotkeys:** ⌃⌥Space (capture), ⌃⌥V (hopper), ⌃⌥C (paste — plugin dispatch
  from clipboard), ⌃⌥O (notice action — registered only while an actionable
  bubble is visible), ⌃⌥M (menu). All configurable via config. The menu
  binding is load-bearing for reachability, not a convenience: `canBecomeKey`
  is false so no menu key equivalent ever fires, `hitTest` limits the
  right-click to opaque sprite pixels, and an `LSUIElement` app is absent from
  Force Quit — without it there is no keyboard route to Settings, Undo, or
  Quit. `showMenuFromHotkey` must activate the app first or menu tracking
  reads key events from whatever is frontmost instead.
- **Pinned vault:** one vault sorts first everywhere (hopper, courier, capture).
  Toggled via pin icon or ⌘P.
- **Launch at login:** `SMAppService.mainApp`, toggled in menu → Settings.
- **Full-screen visibility:** `collectionBehavior`-based, toggled in Settings.
  orderOut/orderFront on toggle to force window-server re-evaluation.
- **Window position** is `PetGeometry`, which is pure and takes `PetScreen`
  rects rather than `NSScreen` — `PetWindow.swift` is AppKit and not in the
  check target, and an unreachable pet is the failure most worth testing, so
  the maths lives where `make check` can reach it (same move as the size and
  opacity presets in `AppState`). `PetWindow` holds thin wrappers that supply
  the current displays. `validatedOrigin` distrusts a saved position that no
  screen intersects and falls back to the default corner; a position that is
  merely partly off, or tucked under the Dock, is **clamped rather than reset**
  — intersection is tested against `frame` but clamping against `visibleFrame`,
  so a position the user chose survives. It runs at launch *and* on
  `didChangeScreenParametersNotification`, because `constrainFrameRect` is
  overridden to a no-op and nothing else rescues a pet stranded by an unplugged
  display. The screen-change path deliberately **does not persist** the rescued
  origin: `state.position` is the position the user picked, and keeping it
  means the pet returns there once the display is back. `PetScene.baselineY` is
  `PetGeometry.Margin.bottom` — one constant, since the scene's baseline and
  the window's bottom margin are the same number.
- **`obsidian` CLI** is an optional enhancement — every CLI call has a direct-FS
  fallback. Trusted path lookup only (never `$PATH`).
- **Plugin system** (api: 1): shell scripts in `~/.config/chestnut/plugins/<name>/`
  with a `manifest.json` declaring accepted pasteboard types and output mode.
  Plugins receive input via env vars + stdin, produce output on stdout. Output
  modes: capture (pre-fill), save (to vault), clipboard, notify, or structured
  JSON envelope for runtime control. Structured envelope supports `attachments`
  array for saving additional files (images, PDFs) alongside a note; attachments
  work with both `save` and `capture` actions. Both copy into the vault's
  configured attachment folder (`Courier.attachmentFolder(of:)` reads
  `attachmentFolderPath` from `.obsidian/app.json`, falling back to the vault
  root only when it's unset) — the envelope's `folder` field moves the note but
  not its attachments. On `capture`, only attachments the submitted note refers
  to by filename are copied; see `partitionAttachmentsByReference`. Scripts are
  exec'd directly (shebang), configurable timeout (default 10s, clamped to
  1–300). Hot-reloaded via
  FSEvents. Installed plugins listed in right-click menu → Plugins submenu (with
  "Open Plugins Folder"); individual plugins can be enabled/disabled from the
  submenu (persisted in `state.json` as `disabledPlugins`). Manifests support an
  optional `extensions` array (e.g. `["txt", "csv"]`) to narrow file-type matching
  within a broad `accepts` category — unmatched files fall through to the courier.
  Folder drops route to a `folder` plugin when one exists; otherwise the courier
  handles them (copies/moves the directory as-is). Non-.md file drops route to a
  matching plugin when one exists; .md drops always go to courier. Zero-cost when
  no plugins installed — courier and all existing features work identically.
- **Vault containment** is a *lexical* prefix check,
  `Courier.isContained(_:inVault:)` — standardized-path prefix (with trailing
  `/`), rejecting `.obsidian` path components. Three callers, all of them
  paths the user did not type by hand: plugin `save` output
  (`AppDelegate.swift:660`), plugin capture attachments (`:421`), and
  `obsidian://` drop resolution (`PetWindow.swift:739`, a read path). It
  collapses `../`, which is the case it exists to catch — a buggy plugin
  emitting `"folder": "../.."`. It does **not** resolve symlinks: a directory
  you symlink out of the vault is followed. That is deliberate, not an
  oversight; see Hard invariants.
  The courier does not call it and does not need to — `deliverNote` builds
  destinations as `dir.appendingPathComponent(source.lastPathComponent)`
  (`Courier.swift:195`), and a `lastPathComponent` cannot contain a `/`, so it
  is contained structurally.

## Hard invariants

- **Never modify Obsidian's files or settings.** Read-only observation of
  `obsidian.json`, vault dirs, `.obsidian/*.json`. Writes only as explicit
  user-initiated actions (courier move, capture append), never to `.obsidian/`.
- **Key vaults by path, never by name** (names collide). `obsidian://open?path=...`
  throughout.
- **No network calls, no telemetry.** "Check for Updates" opens the GitHub
  releases page in a browser.
- **Courier never overwrites:** name conflicts get Obsidian-style suffixes;
  every operation is journaled for undo. Journals are capped
  (`JournalLimits`: 20 records, 1 MB) and rewritten atomically on every
  append — a courier record can carry a whole note body in
  `NoteRewrite.original`, so both limits are load-bearing. **`last()` and
  `removeLast()` both resolve the top record through `Journal.topIndex`**,
  which walks back past any line that won't decode. Atomic appends mean this
  build can't tear a line, but every journal written by a pre-0.5 build could
  be, and a strict `last()` returned nil there — which reads as "nothing to
  undo", disables the row, and so puts Discard Entry out of reach too. Keep
  them resolving the top the same way: one counting records while the other
  counted lines would reverse a single operation twice against real files.
  Undo depth is
  *not* a feature to grow: a record whose undo fails is kept by default, and
  until it is dealt with it blocks every older record behind it. The failure
  alert therefore offers **Keep** (default) or **Discard Entry**; discarding
  calls `removeLast()` and touches no files.
  **`Courier.undo` attempts every transfer exactly once** — one that can't be
  reversed (usually a delivered file the user has since deleted or renamed in
  Obsidian) is collected, not fatal, and the rest still come home. Hard-stopping
  stranded every transfer behind the failure with nothing saying which. It then
  throws `CourierError.partiallyUndone(restored:unreachable:)`, which names the
  files that stayed put; `Capture.undo` needs no equivalent because it only ever
  throws *before* touching anything (`trashAttachments` already skips what it
  can't trash, for the same reason). The alert distinguishes the two: only a
  refusal may promise "nothing was changed", and a partial undo says instead
  that retrying won't finish the job — the record is spent, since a second pass
  can only re-fail on the transfers already reversed. Undo is for "take back
  what I just did". Each Undo row names the record it would reverse on a second line
  (`NSMenuItem.subtitle`, from `CourierOperation.undoMenuSubtitle` /
  `CaptureRecord.undoMenuSubtitle`) — undo pops one record per click, so a
  bare title refers to a different, older operation from the second click on.
  **The name belongs in the subtitle, not the title**: `NSMenu` sizes to its
  widest row, and a name in the title took the menu from 248pt to 331pt for a
  13-character note name and 476pt at worst. As a subtitle it measured 248pt
  unchanged up to ~20 characters. `subtitle` needs macOS 14.4 while the floor
  is 14.0, so 14.0–14.3 draws the row unnamed. `CourierOperation.deliveredNames`
  carries the dropped file names and is optional, so pre-0.5 records decode
  with it nil and also draw unnamed.
- **Vault containment is lexical, and that is the whole promise.** Plugin
  writes refuse paths that *lexically* resolve outside the vault root
  (standardized-path `hasPrefix`). Symlinks are not resolved. Do not "harden"
  this into a `realpath` check without re-reading the threat model: every
  write-side caller is fed by a plugin envelope, plugins are shell scripts
  already running as the user with full filesystem access, and the only way a
  symlink enters a vault is if the user put it there. Resolving would break a
  symlinked attachment folder to buy a guarantee that `cp` bypasses anyway.
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
- **No em-dashes in site copy.** Use commas, colons, or separate sentences.
  (Code comments in `docs/*.js` / `docs/*.css` are exempt.)
- Demos will drift if the real panels or menu change — reminder comments sit in
  the relevant Swift source files.

## Not notarized

Users clear Gatekeeper via right-click -> Open (pre-macOS 15) or System Settings ->
"Open Anyway" (macOS 15+), or `xattr -dr com.apple.quarantine`. Notarization is
undecided.
