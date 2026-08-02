# Chestnut — partner for Obsidian

Native macOS desktop companion for Obsidian users (one vault or many). An always-on-top pixel-art treasure-chest creature ("Chestnut") that reacts to writing activity and acts as a control surface across vaults. Free app funded by GitHub Sponsors, no license mechanism, no paywall, no network calls. Current release is `VERSION` in the Makefile (0.7.1), shipped as a DMG and a Homebrew cask (`gapmiss/tap/chestnut`, a separate repo — see RELEASING.md).

## Where things are documented

**Rationale lives next to the code it governs.** The dense "why is it like this" prose is in doc comments on the types themselves, not here. This file carries orientation, the rules that must never break, and an index pointing at the rest.

| Document | Covers |
|---|---|
| `ARCHITECTURE.md` | Design that spans files: layers, settings split, menu structure, keyboard reachability, drop routing, containment, website mirroring, distribution |
| `PLUGINS.md` | Plugin authoring: manifest, env vars, output modes, JSON envelope |
| `CONTRIBUTING.md` | Ground rules and code style for outside PRs |
| `RELEASING.md` | Release process, Homebrew tap, notarization status |
| Doc comments | Everything else — see the tripwire index below |

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

- Swift 6 language mode, strict concurrency. UI types are `@MainActor`.
- Min deployment target: macOS 14.
- `LSUIElement` app — no Dock icon, no main menu.
- Version source of truth: `VERSION` in Makefile, stamped into bundle plist.

**Testing:** this machine has Command Line Tools only (no Xcode) — no XCTest or Swift Testing. `make check` compiles `Checks/main.swift` directly against source files and runs assertions (registry parsing, FSEvents, URL building, courier traversal, sprite drift checks). Extend it when adding testable logic. In-app invariants stay as runtime `precondition`s.

**Bash output truncation:** the harness silently truncates long stdout. Never rely on seeing full output. Always pipe through `tail -n N` or `grep`. For `make check`:

```bash
make check 2>&1 | grep -E "FAIL|ALL CHECKS|FAILED"; echo "exit: $?"
```

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
    DropRouter.swift      # pure drop routing (testable)
    PluginPalette.swift   # picker UI for multiple matching plugins

  Support/
    Config.swift          # JSON config (user-owned, hand-edited)
    AppState.swift        # JSON state (app-owned, menu-driven)
    Hotkeys.swift         # global hotkey registration (Carbon)
    Journal.swift         # courier/capture operation journal for undo
    ObsidianCLI.swift     # trusted-path CLI lookup (/opt/homebrew, /usr/local)
    AppInfo.swift         # version, URLs (GitHub releases, GitHub Sponsors)

Scripts/                  # code generators (no runtime dependency)
Resources/                # Info.plist, AppIcon.icns
Checks/main.swift         # runtime test assertions (make check)
docs/                     # hand-written landing page (GitHub Pages root)
```

## Hard invariants

Breaking any of these is a bug, not a trade-off.

- **Never modify Obsidian's files or settings.** Read-only observation of `obsidian.json`, vault dirs, `.obsidian/*.json`. Writes only as explicit user-initiated actions (courier move, capture append), never to `.obsidian/`.
- **Key vaults by path, never by name.** Names collide. `obsidian://open?path=…` throughout.
- **No network calls, no telemetry.** "Check for Updates" opens the GitHub releases page in a browser.
- **The `obsidian` CLI is optional.** Every CLI call needs a direct-filesystem fallback; everything works with Obsidian closed or the CLI missing. Trusted-path lookup only, never `$PATH`.
- **The courier never overwrites.** Name conflicts get Obsidian-style suffixes, and every operation is journaled for undo.
- **The app never writes `config.json`** except `createIfMissing()` on first run. Anything gaining a UI moves to `AppState`.
- **Vault containment is lexical, and that is the whole promise.** Plugin writes refuse paths that *lexically* resolve outside the vault root. Symlinks are not resolved. Do not "harden" this into a `realpath` check without re-reading the threat model: every write-side caller is fed by a plugin envelope, plugins are shell scripts already running as the user with full filesystem access, and the only way a symlink enters a vault is if the user put it there. Resolving would break a symlinked attachment folder to buy a guarantee that `cp` bypasses anyway.
- **No image assets.** Sprites are hand-coded matrices; `docs/sprites.js` is generated by `make site` and `make check` fails on drift.
- **No reuse of Obsidian's gem logo.** "for Obsidian" nominative phrasing only.
- **Cross-Vault Search is permanently out of scope.** Decided early, won't build it.
- **Undo depth is not a feature to grow.** Undo is for "take back what I just did".

## Tripwire index

Each line is a verdict you can act on without opening anything, plus where the full account lives. **Read the cited comment before changing the thing it describes** — every one of these records a fix that was measured, or an approach that was tried and reverted.

### Panels and accessibility

- Palettes are sized **once**, at open; measure *before* clearing `sizingOptions` or the panel opens invisible → `Sources/Chestnut/Panels/PetPanel.swift:host`
- The row a palette **opens** on is announced separately from a move; the 1800ms delay is tuned by ear and moving the sentence to `.accessibilityLabel` was tried and is silent → `Sources/Chestnut/Panels/PetPanel.swift:announceOnOpen`
- Selection moves are announced explicitly; row traits alone are silent while focus stays in the filter field → `Sources/Chestnut/Panels/VaultPalette.swift:announceSelection`
- Hover must not arm until the pointer moves, and the selection half must use `.onContinuousHover`, never `.onHover` → `Sources/Chestnut/Panels/PetPanel.swift:HoverArming`
- Every spoken announcement posts through one site → `Sources/Chestnut/Panels/PetPanel.swift:announceToVoiceOver`

Changes here can only be verified with VoiceOver actually running (⌘F5). Nothing in `make check` can hear. `Panels/` is outside the check target.

**The pointer vanishing when a palette opens under it is AppKit, not us** — a key event with a focused text field calls `NSCursor.setHiddenUntilMouseMoves(true)`. Checked against released 0.7.0, which contains none of the arming code, and the cursor vanishes identically. Do not "fix" it.

### Pet window and geometry

- Reduce Motion freezes the *effect*, not the frame rate; the menu can add stillness but never take it away → `Sources/Chestnut/Pet/PetScene.swift:setMotionFrozen`
- A saved position no screen intersects is reset; one merely partly off is *clamped*, and the rescue deliberately does not persist → `Sources/Chestnut/Pet/PetGeometry.swift:validatedOrigin`
- The menu flips above the sprite when it won't fit below → `Sources/Chestnut/Pet/PetGeometry.swift:menuOrigin`
- The `menu` hotkey is unregistered for as long as the menu tracks, or Carbon queues every press and replays them → `Sources/Chestnut/Support/Hotkeys.swift:setMenuHotkeyEnabled`
- A failed *menu* binding raises a notice; the other four only log. `InstallEventHandler` failing means register **nothing** → `Sources/Chestnut/Support/Hotkeys.swift:onMenuHotkeyFailure`

### Courier, capture and undo

- `Courier.undo` attempts every transfer exactly once; failures are collected, not fatal → `Sources/Chestnut/Actions/Courier.swift:partiallyUndone`
- A failed note read is thrown, never coerced to `""` — the coercion moved notes without their attachments and reported success → `Sources/Chestnut/Actions/Courier.swift:unreadableNote`
- The two containment variants differ on the vault root, deliberately → `Sources/Chestnut/Actions/Courier.swift:isContainedDirectory`
- `last()` and `removeLast()` must resolve the top record the same way, past any line that won't decode → `Sources/Chestnut/Support/Journal.swift:topIndex`
- An oversized record sheds its *copy* payload, never its undo instruction; the two record types answer differently and the asymmetry is the design → `Sources/Chestnut/Support/Journal.swift:JournalShedding`
- Undo rows name their record in the **subtitle**, not the title — `NSMenu` sizes to its widest row → `Sources/Chestnut/Actions/Courier.swift:undoMenuSubtitle`
- The direct-FS capture append can race Obsidian's debounced save; the CLI path is already preferred where it can be trusted → `Sources/Chestnut/Actions/Capture.swift:appendDirectly`

### Plugins and drops

- `Route` has **no plugin-only case**, and making it unrepresentable is what stops a refactor from restoring the shadowing → `Sources/Chestnut/Plugins/DropRouter.swift:Route`
- A folder dragged from Obsidian's explorer arrives as a bare basename; divert *before* `classifyDrag` → `Sources/Chestnut/Plugins/DropRouter.swift:isPathlessObsidianDrag`
- A multi-select arrives as one run-on string; split on the scheme rather than parsing the payload once → `Sources/Chestnut/Actions/ObsidianBridge.swift:ObsidianOpenLink`
- Pasted images pick **PNG over TIFF**, and the extension comes from the same decision as the bytes → `Sources/Chestnut/Plugins/PluginDispatch.swift:imagePayload`
- Filenames are one grammar; the envelope used to bypass it → `Sources/Chestnut/Plugins/PluginRunner.swift:sanitizedFilename`
- On `capture`, only attachments the submitted note refers to are copied → `Sources/Chestnut/Actions/Capture.swift:partitionAttachmentsByReference`
- The registry creates the plugins directory **before** watching it; deleting that line costs hot-reload for the whole session → `Sources/Chestnut/Plugins/PluginRegistry.swift:start`
- Courier candidacy is passed in from the drop site and must never be re-derived, or ⌃⌥C offers delivery of a temp file that gets deleted → `Sources/Chestnut/AppDelegate.swift:discardPendingPluginTemp`

## Conventions

- The pet is "Chestnut" in copy, never "the chestnut". Generic noun: "a pixel-art treasure chest creature".
- No em-dashes in site copy (`docs/`). Code comments there are exempt.
- Don't hard-wrap prose in Markdown; let it soft-wrap.
- When you fix something subtle, put the account in a doc comment beside the code and add a one-line verdict to the tripwire index above. `make check` verifies every pointer here still resolves.
