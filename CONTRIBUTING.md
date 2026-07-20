# Contributing to Chestnut

Thanks for your interest! Chestnut is a small, hand-crafted app and aims to
stay that way — readable, conventional code over clever code.

## Building

You need macOS 14+ and a Swift 6 toolchain. Xcode's Command Line Tools are
enough; there is deliberately **no Xcode project** (please don't add one).

```bash
make build    # swift build (CONFIG=debug|release)
make run      # build → .build/Chestnut.app → launch
make check    # the test suite — run before every PR
make site     # regenerate docs/sprites.js from the Swift sprite sources
pkill -x Chestnut   # quit (menu-bar-less app; or right-click → Quit)
```

## Tests

There is no XCTest target — `make check` compiles `Checks/main.swift`
directly against the sources it exercises (registry parsing, courier moves
on temp dirs, watcher end-to-end, hotkey parsing, sprite drift checks) and
runs the assertions. If you add testable logic, extend `Checks/main.swift`.
In-app invariants stay as runtime `precondition`s.

## Ground rules

These are load-bearing; PRs that break them won't land:

- **Never modify Obsidian's files or settings.** `obsidian.json`, vault
  dirs, and `.obsidian/` are read-only. Writes happen only as explicit
  user actions (courier move, capture append) — never to `.obsidian/`.
- **Key vaults by path, never by name** (names collide in the real world).
- **The `obsidian` CLI is optional.** Every CLI call needs a direct-
  filesystem fallback; the app must work with Obsidian closed or the CLI
  absent.
- **No network calls, no telemetry. None.**
- **Courier never overwrites** — conflicts get suffixed names, every
  operation is journaled for undo.
- **No image assets.** Sprites are hand-coded string matrices mapped
  through a palette. The website's sprites (`docs/sprites.js`,
  `docs/favicon.svg`) are generated from the Swift sources via
  `make site` — never hand-edit them; `make check` fails on drift.
- **Layer split:** AppKit is a thin window/host layer, SpriteKit renders
  the pet, SwiftUI renders panels.

## Code style

- Swift 6 language mode, strict concurrency; UI types are `@MainActor`.
- Match the existing code's tone: small modules, descriptive names,
  doc comments that explain *why* when the code can't.
- The landing page (`docs/`) is hand-written HTML/CSS/vanilla JS with no
  build step — keep it that way. Its panel/menu demos re-create the app's
  UI; if you change `VaultPalette`, `CapturePanel`, the right-click menu,
  or delivery behavior, mirror it there (reminder comments mark the spots).

## Out of scope

- **Cross-Vault Search** — permanently out of scope, by decision. Please
  don't propose it.
- Auto-updaters, analytics, or anything else requiring network access.

## Pull requests

1. Fork, branch, make the change.
2. `make check` must pass.
3. Keep PRs focused — one change per PR.
4. Describe the user-visible behavior change; screenshots or a short
   screen recording help a lot for anything visual.

For bigger ideas, open an issue first so we can talk before you invest
the time.
