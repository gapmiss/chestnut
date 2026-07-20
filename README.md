# Chestnut

A native macOS desktop companion for multi-vault Obsidian users.

Chestnut is an always-on-top pixel-art treasure-chest creature that reacts to your
writing activity and acts as a control surface across all your vaults. It watches
the filesystem directly — no Obsidian plugin required, no settings modified.

## Features

- **Vault Hopper** — see all registered vaults at a glance. ⏎ opens the selected
  vault, ⌘⏎ jumps straight to today's daily note, ⌥⏎ reveals the vault in Finder.
- **Pinned vault** — pin your "home" vault with the hover pin icon in any vault
  list (or ⌘P). It sorts to the top everywhere, starts pre-selected as courier
  destination and capture target, and is always ⌘1 in the capture panel.
- **Note Courier** — drag files onto the pet and pick a destination vault to
  move or copy them. Notes (`.md`) land at the vault root; embedded attachments
  (`![[…]]` and `![](…)`) are resolved from the source vault and carried along,
  with references rewritten to match the destination layout. Embeds of other
  notes are never carried — drop both notes on the pet to move them together.
  Any other file type lands in the vault's attachment folder. Conflict-safe
  naming, journaled for undo.
- **Quick Capture** — jot markdown thoughts into any vault from a floating panel.
  Formatting toolbar, keyboard shortcuts (⌘B, ⌘I, ⌘K; ⌘1-⌘9 pick the vault).
  An interrupted capture keeps both its draft and its target vault until you
  come back.
- **Speech-bubble receipts** — after a capture or delivery, the pet tells you
  exactly where your text went ("Captured to Work › 2026-07-16.md"). Click the
  bubble to see the result in Obsidian: notes open in a tab, and so do delivered
  images, audio, video, and PDFs (via the optional `obsidian` CLI); other file
  types and multi-file drops are highlighted in Obsidian's file explorer.
  Without the CLI, the bubble opens the destination vault instead. The bubble
  fades away on its own.
- **Pet animations** — idle, peek, writing, chomp, carry, deliver, sleep. Hand-coded
  pixel-art frames with swappable color themes.

## Install

Download `Chestnut.dmg` from the latest release, open it, and drag
**Chestnut.app** into **Applications**.

Chestnut is ad-hoc signed (not notarized). macOS Gatekeeper will block the
first launch. To allow it:

- **Right-click** the app → **Open** → click **Open** in the dialog, or
- Remove the quarantine flag from the terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Chestnut.app
```

To start Chestnut automatically, right-click the pet → **Launch at Login**.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode or Command Line Tools) — only needed to build from source
- No Xcode project needed — builds with SPM + Make

## Build & Run

```bash
make build          # swift build (CONFIG=debug|release)
make bundle         # build → .build/Chestnut.app (ad-hoc codesign)
make run            # bundle + open the app
make dmg            # release build → .build/Chestnut.dmg
make check          # runtime checks (no XCTest dependency)
make clean
```

Quit the app with right-click → Quit, or:

```bash
pkill -x Chestnut
```

## Architecture

Single Swift executable bundled into a `.app` by the Makefile.

| Layer | Technology | Role |
|-------|------------|------|
| Windows | AppKit | Borderless, transparent, always-on-top pet window |
| Pet rendering | SpriteKit | Sprite animation from hand-coded frame matrices |
| Panels | SwiftUI | Vault palette, capture bubble, settings |

```
Sources/Chestnut/
  main.swift, AppDelegate.swift
  Pet/        # PetWindow, PetScene, Sprites, PetController (state machine)
  Vaults/     # VaultRegistry, VaultWatcher
  Actions/    # ObsidianBridge, Courier, Capture
  Panels/     # SwiftUI palettes/panels (NSPanel-hosted)
  Support/    # Config, Hotkeys, Journal
```

## Configuration

Settings live in `~/Library/Application Support/Chestnut/config.json`, created
on first run. The file is hand-editable; changes take effect on next launch.

### Hotkeys

Global keyboard shortcuts are registered at startup. Defaults:

| Action | Default | Description |
|--------|---------|-------------|
| Quick Capture | `control+option+space` | Toggle the capture panel |
| Vault Hopper | `control+option+v` | Toggle the vault palette |
| Open notice | `control+option+o` | Open the note behind the speech bubble; only active while a bubble is showing |

Override them in the config file:

```json
{
  "hotkeys": {
    "capture": "control+option+space",
    "hopper": "control+option+v",
    "notice": "control+option+o"
  }
}
```

Keys: `a`-`z`, `0`-`9`, `space`, `tab`, `return`, `escape`, `delete`, `f1`-`f12`.
Modifiers: `control`/`ctrl`, `option`/`alt`, `command`/`cmd`, `shift`.
Set a binding to `""` or `"none"` to disable it.

### Quick Capture destination

Captures append to a note in the selected vault. Chestnut resolves the
target in priority order:

1. **Obsidian daily note** — if the daily-notes core plugin is enabled (the
   Obsidian default), captures append to today's daily note using the vault's
   configured format and folder. The note is created if it doesn't exist.
2. **Chestnut daily note** — if Obsidian's plugin is disabled but you've set
   `captureFormat` in the config, Chestnut formats its own daily note path
   using the same Moment.js token subset (`YYYY`, `YY`, `MM`, `M`, `DD`, `D`,
   `[literal]`).
3. **Inbox fallback** — if neither of the above resolves, captures go to a
   static file (`Inbox.md` by default) at the vault root.

```json
{
  "captureFormat": "YYYY-MM-DD",
  "captureFolder": "captures",
  "captureInboxName": "Inbox.md"
}
```

With the example above and Obsidian's daily notes off, a capture on 2026-07-15
appends to `captures/2026-07-15.md`. Omit `captureFolder` to place notes at
the vault root. Omit `captureFormat` to use the static inbox.

The Vault Hopper's ⌘⏎ opens the same resolved note, so "where capture writes"
and "where ⌘⏎ takes you" always agree. Opening is read-only: if today's note
doesn't exist yet, the vault opens instead (only capture creates notes).

### Pinned vault

Pinning is toggled from the UI (hover pin icon or ⌘P in any vault list) and
stored as `pinnedVaultPath` (an absolute vault path, hand-editable):

```json
{
  "pinnedVaultPath": "/Users/you/Vaults/main"
}
```

When set, that vault sorts first in every vault list and wins the capture
panel's default — unless an unfinished draft is targeting another vault, in
which case the draft's own target is restored with it. Without a pin, the
capture default falls back to the vault that last received a capture. A pin
pointing at a vault no longer in Obsidian's list is ignored.

### Custom themes

Four built-in themes ship with Chestnut: Obsidian Night (default), Classic
Wood, Brushed Steel, and Sunbleached (a warm light theme). Define your own in
the config file and they appear in the right-click Theme menu:

```json
{
  "customThemes": [
    {
      "id": "dracula",
      "title": "Dracula",
      "palette": {
        "s": "#44475A",
        "S": "#6272A4",
        "d": "#282A36",
        "m": "#BD93F9",
        "o": "#191A21"
      }
    }
  ]
}
```

Required shell roles (hex values, `#RRGGBB` or `#RRGGBBAA`):

| Role | Key | Description |
|------|-----|-------------|
| Shell | `s` | Main body color |
| Highlight | `S` | Rivets, raised edges |
| Shadow | `d` | Recessed areas, dial face |
| Trim | `m` | Metal fittings, dial ring |
| Outline | `o` | Border pixels |

Optional overrides — these have shared defaults across all themes but can be
customized per-theme: `p`/`P` (gem / gem glint), `k` (mouth interior),
`t` (tongue), `e` (eye white), `b` (pupil), `z` (sleep pixels).

Themes with duplicate ids, missing required roles, or invalid hex are skipped
with a log message.

For single-color tweaks without a full theme, use `petPalette` to override
individual roles on top of the active theme:

```json
{
  "petTheme": "classic-wood",
  "petPalette": { "m": "#C0C0C0" }
}
```

## Design Principles

- **Read-only observation.** Never modifies Obsidian's files or `.obsidian/` settings.
- **Vaults keyed by path, not name** (names collide in practice).
- **No network calls, no telemetry.**
- **`obsidian` CLI is optional.** Every CLI call has a direct-filesystem fallback;
  works with Obsidian closed or the CLI absent.
- **No image assets.** Sprites are string matrices mapped through a color palette
  to `SKTexture` with nearest-neighbor filtering.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions and ground
rules.

## License

[MIT](LICENSE) © [@gapmiss](https://github.com/gapmiss)
