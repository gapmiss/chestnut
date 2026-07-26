# Changelog

Notable, user-facing changes to Chestnut. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **A hotkey that opens the menu: ⌃⌥M.** Every setting Chestnut has lived
  behind a right-click that had to land on the sprite itself, and because the
  pet window never takes keyboard focus, no menu shortcut could fire either.
  That made Size, Theme, Settings, Plugins, both Undo items and **Quit**
  reachable by exactly one gesture. It also meant anyone who couldn't make
  that click had no way out of the app: Chestnut has no Dock icon and no menu
  bar item, and an app like that doesn't appear in Force Quit, so quitting
  meant Activity Monitor or a terminal. ⌃⌥M now opens the same menu at
  Chestnut, and arrow keys and Return work in it. Rebindable as `menu` in
  `config.json`.

### Changed

- **Opacity and Notice Bubble are now lists of choices, not sliders.** A
  slider in a menu is a custom view, and macOS skips those when you move
  through a menu with the arrow keys, so neither value could be changed
  without a mouse even once ⌃⌥M opened the menu. Opacity was the one that
  could strand you: faded to its minimum Chestnut is nearly invisible, and the
  only control that could restore it was a slider you had to find and drag on
  a sprite you could no longer see. Each now opens a short list with the
  current value checked, reachable by keyboard or mouse: opacity at 100, 80,
  60, 40 and 20 percent, and notice bubbles at 3, 5, 10, 20 and 30 seconds.
  The trade is deliberate, and it is the reason these are the only two places
  the menu goes three levels deep. If you had picked a value between those
  stops, it is kept and keeps working, but no row is checked until you pick
  one of the listed values.

### Fixed

- **The undo journals no longer grow without limit.** Every delivery and
  capture was recorded forever, and a delivery that rewrote a note's links
  stored a complete copy of that note's text in the record. The journals now
  keep the 20 most recent entries, and drop older ones if the file still
  exceeds 1 MB. Existing journals are trimmed the next time you deliver or
  capture. This does shorten how far back Undo can reach, which in practice
  it could not reach anyway: the menu never said which delivery it was about
  to reverse, and an entry that fails to undo is kept and blocks everything
  older than it.

- **The plugin guide documented the wrong field name, so every copy-pasted
  manifest silently failed to load.** The manifest reference and both worked
  examples called the script field `command`; the parser has always required
  `script`. A plugin built by following the guide never appeared in the
  Plugins menu and produced no error anywhere. The docs are corrected, and a
  manifest Chestnut rejects now writes the reason to the debug log — naming
  the offending key, the unknown output mode, or the script it could not
  execute — instead of disappearing without a word.

- **The structured-envelope reference described three fields wrongly.**
  `vault` was documented as a name hint, and the worked example used a vault
  name, which matches nothing and raises "Unknown vault" — the working values
  are `pinned`, `last`, `ask` or an absolute vault path, none of which were
  documented. `filename` was documented as defaulting to the first line of the
  content; a structured envelope that omits it actually gets `Untitled.md`.
  And attachments were documented as landing in the note's folder or the vault
  root, when both paths use the vault's configured attachment folder. The
  input-types table was also missing `pdf` and `any`, though `pdf` is used by
  a shipped example.

- **A plugin's attachments no longer follow you to an unrelated capture.**
  If a plugin queued a file and you dismissed the capture panel instead of
  submitting, that file stayed queued for the rest of the session and was
  copied into whatever you captured next, in whatever vault. Attachments are
  now copied only when your note refers to them, which is what the plugins
  were already writing into the draft as `![[filename]]`. Delete the link and
  the file is dropped; rewrite the draft into something else and nothing
  follows. Dismissing still keeps your draft exactly as before.

- **Undo Last Capture now reverses the attachments as well as the text.**
  Undoing a capture that a plugin had added images to used to report success,
  remove the text, and leave every image sitting in your vault with no record
  they belonged to it. Those files now go to the Trash along with the text,
  never deleted. An undo that refuses because the note changed underneath it
  leaves the files alone, as before.

- **A capture that fails no longer leaves files behind, or loses what you
  typed.** Attachments used to be copied into the vault before the note was
  written, so a failed capture stranded them with nothing referring to them.
  The note is written first now. And because submitting cleared the draft
  before the write, "Capture failed" used to take your text with it; the draft
  and any attachments now come back, so you can retry or copy the text out.

- **A hotkey without a real modifier is now refused instead of taking over
  the key.** `"capture": "space"` was accepted and registered, and because a
  global hotkey takes the keystroke away from every other application, it left
  you without a space bar anywhere on the system until you quit Chestnut. A
  binding now needs at least one of control, option or command; shift can be
  added to those but doesn't count on its own, since `shift+a` is just A.
  Bindings that don't qualify are ignored and the reason is written to the
  log, the same as any other unparseable binding.

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
