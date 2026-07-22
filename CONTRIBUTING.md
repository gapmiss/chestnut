# Contributing to Chestnut

Thanks for stopping by! Chestnut is a small app and I'd like to keep it that
way. Plain, readable code beats clever code here.

## Building

You need macOS 14+ and a Swift 6 toolchain. Xcode's Command Line Tools are
enough. There's no Xcode project on purpose, so please don't add one.

```bash
make build    # swift build (CONFIG=debug|release)
make run      # build → .build/Chestnut.app → launch
make check    # the test suite — run before every PR
make site     # regenerate docs/sprites.js from the Swift sprite sources
pkill -x Chestnut   # quit (no Dock icon; or right-click the pet → Quit)
```

## Tests

There's no XCTest target. Instead, `make check` compiles `Checks/main.swift`
directly against the sources it exercises (registry parsing, courier moves on
temp dirs, watcher end-to-end, hotkey parsing, sprite drift checks) and runs
the assertions. If you add logic that can be tested, add checks for it there.
In-app invariants are runtime `precondition`s.

## Ground rules

A few things the whole app is built around. PRs that break these won't land,
so it's worth knowing them up front:

- Never modify Obsidian's files or settings. `obsidian.json`, vault dirs, and
  `.obsidian/` are read-only. Chestnut only writes when the user asks it to
  (courier move, capture append), and never inside `.obsidian/`.
- Vaults are keyed by path, not by name. Names collide in the real world.
- The `obsidian` CLI is optional. Every CLI call needs a direct-filesystem
  fallback; everything has to work with Obsidian closed or the CLI missing.
- No network calls, no telemetry.
- The courier never overwrites anything. Conflicts get suffixed names, and
  every operation is journaled so it can be undone.
- No image assets. Sprites are hand-coded string matrices mapped through a
  palette. The website's sprites (`docs/sprites.js`, `docs/favicon.svg`) are
  generated from the Swift sources via `make site` — don't hand-edit them,
  `make check` will fail if they drift.
- Layers: AppKit is a thin window/host layer, SpriteKit renders the pet,
  SwiftUI renders panels.

## Code style

- Swift 6 language mode, strict concurrency; UI types are `@MainActor`.
- Match the surrounding code: small modules, descriptive names, comments that
  explain *why* when the code can't say it on its own.
- The landing page (`docs/`) is hand-written HTML/CSS/vanilla JS with no build
  step, and stays that way. Its panel and menu demos re-create the app's UI,
  so if you change `VaultPalette`, `CapturePanel`, the right-click menu, or
  delivery behavior, update the site too (there are reminder comments at the
  relevant spots).

## Out of scope

- Cross-vault search. Decided against it early on and that's not changing,
  so please don't propose it.
- Auto-updaters, analytics, or anything else that needs network access.

## Pull requests

1. Fork, branch, make the change.
2. `make check` must pass.
3. Keep PRs focused — one change per PR.
4. Describe what changes for the user. Screenshots or a short recording help
   a lot for anything visual.

Got a bigger idea? Open an issue first so we can talk it over before you
sink time into it.
