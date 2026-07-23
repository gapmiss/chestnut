# Changelog

Notable, user-facing changes to Chestnut. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

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

[0.2.0]: https://github.com/gapmiss/chestnut/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/gapmiss/chestnut/releases/tag/v0.1.0
