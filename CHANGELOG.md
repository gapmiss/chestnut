# Changelog

Notable, user-facing changes to Chestnut. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [0.4.0] — 2026-07-25

### Added

- **Notice duration is now a menu control.** Right-click → Settings → Notice
  Bubble, a slider from 1 to 30 seconds with a live readout. It applies to the next
  speech bubble, with no relaunch, which makes it possible to actually tune
  by watching instead of by editing a file and restarting.

- **Right-click → Settings → Edit Configuration…** opens `config.json` in
  whatever you edit JSON with, and says that changes apply on next launch. If
  nothing is registered for `.json`, it reveals the file in Finder instead.

### Changed

- **The right-click menu is reorganized: 16 top-level rows down to 11.**
  Nothing was taken away and everything is still reachable. Actions come first
  now, ordered by how often they're used, so Vaults…, Capture… and the two Undo
  rows sit at the top instead of below four appearance settings.

  Size and Theme have not moved. The set-once settings collect into a new
  **Settings** submenu: Opacity, Notice Bubble, Copy on Drop, Show in Full
  Screen, Launch at Login, Reset Position and Edit Configuration…. Five of those
  moved down a level; Notice Bubble and Edit Configuration… are new in this
  release. Opacity is a plain row there rather than a submenu of its own, with a
  label and a live percentage, so nothing in the menu opens a third level.

  The version dropped its own greyed-out row and rides along as a badge on
  Check for Updates…, where it's still there to quote in a bug report.

- `noticeDuration` moved from `config.json` to `state.json`, following the
  rule that anything with a UI is Chestnut's to write.

- **Settings migrations are gone, and won't come back.** Both files tolerate
  unknown and missing keys, so a file written by any version loads under any
  other and a stale key can never break a launch. That tolerance is what makes
  migration code unnecessary, and dropping it keeps the write invariant
  exception-free: Chestnut writes `config.json` only when creating it from
  scratch.

  The one visible cost is a release that relocates a setting, as this one does
  to notice duration: the value goes back to its default and you set it again
  from the menu. A leftover key in the file it came from is ignored, not
  deleted; remove it yourself or leave it. Nothing hand-edited is touched.

## [0.3.0] — 2026-07-24

### Changed

- **Settings are now two files.** `config.json` holds only what you edit by
  hand (hotkeys, custom themes, capture destination, notice duration, debug).
  Everything Chestnut sets for itself (window position, size, opacity, theme,
  pinned vault, disabled plugins, last capture vault) moved to a new
  `state.json` beside it. Chestnut no longer writes `config.json` at all,
  apart from creating it on first run.

  **Migration is automatic** on first launch: the old file is split, and the
  original is kept as `config.json.pre-0.3`. Nothing to do. Rolling back to
  0.2.x afterwards resets window position, size, and theme to defaults;
  restore the `.pre-0.3` file to get them back.

- `disabledPlugins` now lives in `state.json` and is managed from the
  right-click menu → Plugins. Hand-editing it is no longer the supported
  path.

### Fixed

- Hand-edits to `config.json` made while Chestnut was running were silently
  overwritten the next time it saved, and a window drag was enough to trigger
  it. Clearing `disabledPlugins` by hand would repopulate. The file split
  removes the cause: the app has nothing to write there.
- An unparseable `config.json` is now moved aside rather than copied, so the
  defaults Chestnut loads can't overwrite JSON you were about to fix. An
  existing `config.json.bak` is no longer clobbered by a second failure;
  backups number upward (`config.json.bak.1`, …) as documented.

## [0.2.1] — 2026-07-22

### Added

- **Capture attachments**: structured plugins can now include an `attachments`
  array with `action: "capture"`. Files are copied to the vault's attachment
  folder when the user submits the capture panel.
- **Example plugins**: `img-clip-daily` (clipboard image to today's daily note)
  and `img-clip-note` (clipboard image as a new note).

### Fixed

- Plugin attachments from clipboard paste (e.g. `img-ocr`) failed because the
  temp file was deleted before it could be copied to the vault.
- Plugin attachments now land in the vault's configured attachment folder
  (per `.obsidian/app.json` `attachmentFolderPath`) instead of always going
  to the vault root or note folder.

## [0.2.0] — 2026-07-22

### Added

- **Plugin system**: extend Chestnut with shell scripts in
  `~/.config/chestnut/plugins/<name>/`. A `manifest.json` declares what the
  plugin accepts (`text`, `url`, `image`, `file`, `folder` — with optional
  `extensions` narrowing) and how output is handled (`capture`, `save`,
  `clipboard`, `notify`, or a structured JSON envelope with attachment
  support). Plugins hot-reload on edit and can be enabled/disabled from the
  right-click menu. See the [user guide](https://gapmiss.github.io/chestnut/guide.html#plugins).
- **⌃⌥C paste hotkey**: classifies clipboard content and dispatches it to a
  matching plugin. A picker appears when several plugins match.
- **⌃⌥O notice hotkey**: keyboard follow-through on the active speech
  bubble, registered only while an actionable bubble is visible.
- **Smarter drag-and-drop**: non-markdown files route to a matching plugin
  (falling back to the courier), folders route to a `folder` plugin when one
  exists, and drops from Electron apps (including Obsidian itself) now work.
  Markdown drops go to the courier, as always.
- **Debug mode**: diagnostic logging to `~/Library/Logs/Chestnut/`.
- **User guide**: full reference for features, plugins, configuration, and
  troubleshooting at [gapmiss.github.io/chestnut/guide.html](https://gapmiss.github.io/chestnut/guide.html).

### Fixed

- Panels no longer lose focus mid-interaction.
- Courier crash when a delivery contained duplicate attachment names.

## [0.1.0] — 2026-07-20

Initial release: an always-on-top pixel-art treasure chest that keeps you
company while you write.

- **Vault Hopper** (⌃⌥V): jump between vaults, open today's daily note,
  reveal in Finder. Pin a favorite vault with ⌘P.
- **Note Courier**: drag markdown files onto the pet to move or copy them to
  another vault — embedded attachments carried along, references rewritten,
  conflict-safe naming, undoable.
- **Quick Capture** (⌃⌥Space): jot markdown into any vault's daily note or
  inbox, with a formatting toolbar and surviving drafts.
- Idle, peek, writing, chomp, carry, deliver, and sleep animations; swappable
  color themes; launch at login; full-screen visibility toggle.
- No network calls, no telemetry, never touches Obsidian's files.

[0.4.0]: https://github.com/gapmiss/chestnut/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/gapmiss/chestnut/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/gapmiss/chestnut/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/gapmiss/chestnut/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/gapmiss/chestnut/releases/tag/v0.1.0
