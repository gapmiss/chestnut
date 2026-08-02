# Changelog

Notable, user-facing changes to Chestnut. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- **Dragging several files at once out of VS Code, VSCodium or any other
  Electron app now delivers all of them.** Selecting two notes and dropping
  them on Chestnut moved only the first, and nothing said the others had been
  left behind. Chromium-based apps do not write the macOS file-list pasteboard
  type that Finder does; they offer a single URL, which was all Chestnut could
  read. The full list travels in a separate Chromium payload, and Chestnut now
  reads it. Only local files that still exist are taken, web links dragged from
  a page are untouched, and anything unexpected in that payload falls back to
  the old single-file behaviour rather than guessing. Finder drags are
  unaffected.

- **A palette no longer arms a row just because it opened underneath the
  pointer.** Both palettes highlight the row the mouse is over, and a panel
  appearing under a stationary cursor counted as a hover even though the
  pointer had not moved. Opening the plugin picker with ⌃⌥C, where the mouse
  is wherever it was last left, could therefore arm the third row instead of
  the first, and pressing ⏎ ran a plugin nobody had chosen. Hover is now
  ignored until the pointer actually moves, the way menus behave. Moving the
  mouse over the list works exactly as before.

- **The palettes now say which row is selected when they open**, for VoiceOver
  users. They already announced each row as ↑/↓ moved through the list, but
  never the row that was selected to begin with, which is the one that governs
  what ⏎ does. The plugin picker announces how many actions there are, which is
  selected, and what it will do; the vault hopper does the same for vaults.

  Known rough edge: the announcement has to wait for VoiceOver to finish
  describing the palette's filter field, and on second and later openings
  VoiceOver may read the palette's keyboard hints before it. The announcement
  is still made.

## [0.7.0] — 2026-07-30

### Changed

- **Installing a plugin no longer takes away a courier gesture.** A plugin that
  matched a dropped file used to claim it outright, so enabling a `folder`
  plugin meant folders could no longer be delivered to another vault, and
  enabling an image plugin meant the same for every image. There was no way to
  say "no, deliver this one". Now, when a plugin and the courier could both
  handle a dropped item, Chestnut asks: the picker lists the matching plugins
  and a **Deliver to a vault** row. The plugin starts selected, so ⏎ does what
  Chestnut did before; ↓ then ⏎ delivers instead.

  Unchanged: `.md` files always go to the courier, several items dropped
  together are always a delivery, and an item no plugin matches still goes
  straight to the courier with no picker. ⌃⌥C is unaffected, since a pasted
  image is not a file the courier can deliver.

- **Attachments dragged out of Obsidian now follow the same rules as files
  from Finder.** They previously bypassed plugin routing entirely, as a
  workaround for the problem above. With the courier always one row away, the
  workaround is gone: a single attachment dragged from Obsidian with a matching
  plugin enabled now opens the same picker. Notes, multi-selections, and the
  folder explanation are unchanged.

### Fixed

- **The plugin picker now announces the selected row to VoiceOver.** Arrowing
  through it was silent, because focus stays in the filter field by design.
  With the courier now reachable only through this picker, choosing blind
  between running a script and moving the file to another vault was not
  acceptable.

## [0.6.2] — 2026-07-30

### Fixed

- **Several notes dragged from Obsidian at once are now delivered.** Selecting
  two or more notes in Obsidian's file explorer and dragging them onto Chestnut
  did nothing useful: Obsidian describes them all in a single run-on link, and
  Chestnut read that as one note with an unrecognizable name, found nothing at
  that name, and offered the dropped text to plugins instead. Neither note
  moved, and nothing said why. Every note in the drag now arrives at the
  destination picker together.

### Changed

- **A folder dragged from Obsidian now explains itself.** Obsidian's file
  explorer hands over a folder as its name alone, with no path and no vault, so
  there is nothing for Chestnut to find. Previously it treated that name as
  ordinary text and opened the plugin picker, which looked like it worked and
  delivered nothing. Chestnut now says that Obsidian drags folders without
  their path, and points at Finder, where the gesture works. Notes and
  attachments dragged from Obsidian are unaffected.

## [0.6.1] — 2026-07-28

### Fixed

- **Chestnut no longer freezes while carrying files.** A delivery did all of
  its work on the same thread that draws the pet and opens the menu, so a
  large copy, or a note with several stale image links in a big vault, could
  leave the pet motionless and every hotkey dead until it finished. macOS
  could even mark the app as not responding. Deliveries now run in the
  background, and Chestnut chews while it works.

- **A note Chestnut cannot read is no longer delivered without its images.**
  If the text of a note could not be read, Chestnut treated the note as empty,
  which meant it found no images to bring along. The note moved anyway and the
  delivery reported success, leaving the images behind in the old vault and
  the links broken in both. The likely cause is a vault in iCloud Drive, where
  a note you have not opened lately may not be downloaded yet. Chestnut now
  says it could not read the note and cancels the delivery.

- **VoiceOver now announces the vault you have arrowed to.** In the Vault
  Hopper and the delivery destination picker, ↑ and ↓ moved the highlight
  without saying anything, because the typing focus stays in the filter field
  and the highlight belongs to no control. VoiceOver announced only "text
  field", however far down the list you got, so pressing ⏎ opened a vault you
  were never told was selected. Each move is now spoken with the vault's name
  and path, along with whether it is open in Obsidian and whether it is
  pinned, which the list otherwise shows only as a coloured dot and an icon.

- **Undo no longer silently leaves a large note's links rewritten.** Chestnut's
  undo log is capped so it cannot grow without bound, but a single record
  larger than the entire cap slipped past the limit — delivering a big note
  whose image links were rewritten wrote that note's whole previous text into
  Application Support and left it there. Chestnut now keeps the record and
  drops the text copy: undo still brings every file home, and it now names the
  notes whose original links it could not put back, instead of handing them
  over quietly. Quick Capture records are never shortened this way, because
  there the saved text is exactly what undo needs to know what to remove.

- **Chestnut no longer claims keyboard shortcuts it cannot answer.** If the
  system handler that dispatches hotkeys failed to install, Chestnut registered
  all five shortcuts regardless. Every one was then reserved system-wide and
  dead everywhere at once: ⌃⌥M did nothing in Chestnut, and nothing in any
  other app either. Chestnut now registers no shortcuts in that case and tells
  you the menu shortcut is unavailable, since the right-click menu is the only
  way to reach Settings, Undo and Quit.

- **A plugin can no longer create a folder outside your vault.** The folder a
  plugin save creates was only checked indirectly, by way of the note path, so
  a plugin pairing a `folder` that pointed outside the vault with a `filename`
  that walked back into it had the outside folder created anyway, while the
  note landed correctly and the save reported success. Only empty folders could
  be made this way and no note text ever left the vault, but the rule is meant
  to cover every path a save creates, and now does.

- **A long reply from the `obsidian` command-line tool no longer stalls.**
  Chestnut waited for the tool to exit before reading what it had printed, so a
  reply bigger than the pipe buffer left the tool stuck mid-write and the call
  timed out. These calls are optional refinements with a direct fallback, so
  the visible effect was only that a follow-up such as revealing the note in
  Obsidian never happened, but it burned the full timeout each time. Both
  output streams are now read while the tool runs.

### Added

- **A note on using Chestnut with VoiceOver.** Control-Option is VoiceOver's
  own modifier key, so while VoiceOver is running it takes ⌃⌥V, ⌃⌥M and the
  rest before Chestnut ever sees them, leaving no working shortcut, ⌃⌥M
  included. The README now says so and gives a `control+shift` set to paste
  into `config.json`. Right-clicking Chestnut still opens the menu meanwhile,
  and the menu, the capture panel and the palettes all read correctly.

### Changed

- **Plugins: filenames in structured output follow the same rules as plain
  save mode.** Path separators become `-`, names are capped at 200 characters,
  and `.md` is added when missing. Previously the structured envelope applied
  none of this, so `"notes/today.md"` failed with a confusing "file doesn't
  exist" and `"today"` silently wrote a file Obsidian would not display. Use
  the `folder` field for subfolders. Attachment filenames are sanitized the
  same way, without forcing `.md`.

## [0.6.0] — 2026-07-27

### Changed

- **Dropping several files at once is always a delivery.** A drop used to
  hand its first non-markdown file to a matching plugin and, until this
  release, quietly discard every file after it: drop three images with an
  image plugin installed and two of them went nowhere, with no notice saying
  so. A plugin run and a delivery also compete for the same screen — the
  vault palette and the speech bubble are one at a time — so a picker opened
  by one could be dismissed by the other before you saw it. Now a drop of two
  or more items is a courier delivery, all of it, even when a plugin would
  have matched the first item. Drop an item on its own to send it to a
  plugin. Nothing is discarded either way.

### Added

- **A second copy of Chestnut now bows out instead of fighting the first.**
  Launching the app from two places at once — the copy in the DMG beside the
  one in Applications is the easy way to do it — gave you two pets, and both
  of them rewrote the same undo journals, so whichever wrote last erased the
  other's records and an undo could simply vanish. The second copy now says
  which copy is already running, and quits.

- **A menu hotkey that never registered now tells you.** ⌃⌥M is the only
  keyboard route to Settings, Undo and Quit, and if another app already owned
  that combination, or the binding in `config.json` didn't parse, Chestnut
  started with that route dead and said nothing anywhere you'd look. It now
  raises a bubble at launch naming the binding and pointing at the file.
  Setting the binding to empty, `none` or `disabled` is taken as meaning it,
  and stays silent.

### Fixed

- **Delivering a note to a vault Chestnut knew under two names could delete
  it.** If Obsidian had recorded the same vault twice, once through a
  symlink, the two paths looked like two vaults, and delivering a note from
  one to the other landed it on top of itself. Chestnut read that as
  delivering a file that was already there, and moving means removing the
  original: the only copy was deleted, and not to the Trash. Chestnut now
  recognizes a file as itself regardless of the path it arrived by, and does
  nothing.

- **A pasted screenshot reached plugins as an image Obsidian can't show.**
  Copying a screenshot puts two versions of it on the clipboard, and Chestnut
  picked one to save and named the file after the other, so a plugin that
  attached the image to a note produced an embed that rendered blank, with a
  `.png` on the end to hide why. The image and its name are now the same
  decision, and it's the PNG, which is what a vault can display and a third
  of the size.

- **Filtering a palette down to nothing no longer shrinks it for good.**
  Type in the vault hopper or the plugin picker until nothing matches, then
  backspace: the full list came back into a slot two rows tall with a
  scrollbar, and stayed that way until you closed and reopened the panel.
  Panels are now sized once, when they open, and the "no matches" message
  fills the space the list left rather than collapsing it.

- **A plugin that starts a background helper no longer leaves Chestnut
  chewing forever.** Backgrounding something (`sleep 5 &`, a helper daemon,
  anything started without redirecting its output) is ordinary shell
  practice, and it kept Chestnut waiting for output that would never end,
  even after the plugin itself had finished: the chewing pose never stopped,
  no result appeared, and only quitting cleared it. The plugin's output is
  now collected as it arrives, so a surviving child can't hold the run open.

- **A plugin that ignores what it's fed no longer crashes the app.** Chestnut
  writes a plugin's input to it on standard input as well as in environment
  variables; a plugin that reads only the variables and exits — perfectly
  reasonable, and what several of the shipped examples do — left that write
  with nowhere to go, and the failure took the whole app down with it. The
  write is now allowed to fail quietly, which is all it ever meant.

- **A plugin's `timeout` is now kept within 1 to 300 seconds.** A manifest
  with `"timeout": 0` had its script killed the instant it started, so every
  single run reported "Plugin timed out" and nothing said why; an enormous
  value let a stuck plugin hold the chewing pose indefinitely. Values outside
  the range are pulled into it and the adjustment is logged, so the author
  finds out.

- **Themes with see-through colors render cleanly.** A custom theme in
  `config.json` may give a color an alpha value, and any value between fully
  transparent and fully opaque came out over-bright with fringes along the
  pixel edges. The built-in themes were never affected.

- **The keys shown in the right-click menu are the keys that work.** The menu
  and the hotkey system read `config.json` with two separate parsers that had
  drifted apart, so a binding like `shift+a` was displayed beside a menu row
  but never fired, and `f1` fired but showed nothing. There is one parser
  now, so the menu can't offer a shortcut that isn't registered.

- **Pasted images no longer leave temp files behind.** An image pasted to a
  plugin is written to a temporary file first. If several plugins matched and
  you dismissed the picker, or you dismissed a capture panel a plugin had
  filled in, that file stayed on disk until macOS got around to it. Cancelled
  pickers now clean up immediately, and anything left from an earlier session
  is swept at launch.

- **The debug log no longer records what you copied.** With `debug` enabled,
  the first 80 characters of pasted text and URLs were written to
  `~/Library/Logs/Chestnut/`, which is a poor place for whatever was on your
  clipboard last. It now records the type and the length only. The log has
  always been off by default and local to your Mac. (A plugin that echoes its
  own input to standard error still puts it in the log by its own hand.)

## [0.5.0] — 2026-07-26

### Added

- **Chestnut holds still when you ask it to, and when macOS already has.** A
  gentle breathing motion ran in every state, forever, on a window that sits on
  top of everything else, and nothing could stop it short of quitting the app.
  Settings ▸ Reduce Motion now stops everything that moves: the breathing, the
  drifting z's while Chestnut sleeps, the hop when you click, and the squash on
  a delivery. Chestnut keeps blinking, chattering while you write and chewing
  while a plugin runs, because those change the sprite without moving it, so
  you can still tell at a glance what it's doing. If Reduce Motion is switched
  on in System Settings ▸ Accessibility ▸ Display, Chestnut holds still on its
  own without being asked, and the menu row says so rather than offering to
  undo it.

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

- **The Undo rows now say what they will undo.** They read "Undo Last
  Delivery" and "Undo Last Capture" no matter what was in the journal, and
  every click reverses one more operation, so from the second click on the
  row referred to something older than the thing you had in mind, with
  nothing on screen to say so. Each row now carries the name of what it would
  reverse on a second line: `recipe.md`, `3 notes`, `2026-07-25.md`. Rows
  stay unnamed when there is nothing to undo, on operations recorded before
  this release, and on macOS 14.0 to 14.3, which has no second line to put
  them on.

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

- **Chestnut no longer gets stranded when you unplug a display.** The pet's
  position was only checked against your screens at launch, so disconnecting
  the display it was sitting on left it at coordinates nothing could reach:
  no sprite to right-click, and the right-click menu is the way to Reset
  Position. It now re-checks whenever your display setup changes and comes
  back to your main screen. Resizing or rearranging displays nudges it clear
  of the menu bar and Dock instead of moving it away. Where you put the pet is
  remembered as you left it, so it returns there once the display is back.

- **Undoing a delivery no longer gives up at the first file it can't move
  back.** If you had deleted or renamed one of the delivered files in Obsidian,
  undo stopped dead there: the files it had already returned stayed returned,
  everything behind that one stayed in the destination vault, and the message
  said only "Undo failed" with no clue which files were where. Undo now tries
  every file in the delivery and brings back all the ones it still can, then
  tells you which it couldn't and why. Nothing is deleted or overwritten to do
  it, and a file that is genuinely gone is still never conjured back.

- **An undo that fails no longer blocks every earlier one.** When an undo
  can't be reversed — most often because the note has been edited since, which
  Chestnut refuses to guess at — the operation was kept on top of the stack
  and every later undo retried that same one and failed the same way, putting
  everything older permanently out of reach. The failure now asks: **Keep**,
  which is the old behavior and still the default, or **Discard Entry**, which
  touches no files and only stops Chestnut offering that operation again, so
  the next undo reaches the one before it.

- **A damaged undo journal no longer switches undo off for good.** Chestnut
  used to add to its undo journals one line at a time, so a crash or a full
  disk could leave a half-written entry at the end of the file. Reading it back
  produced nothing Chestnut could make sense of, and it concluded there was
  nothing to undo at all: the Undo row greyed out, and since a greyed-out row
  can't be clicked, there was no way to skip past the damage either. Every
  operation recorded before it was out of reach for good. Chestnut now reads
  back to the last entry it does understand, and tidies the damage away as you
  undo. Journals are also written whole now rather than a line at a time, so
  new ones can't be left half-finished in the first place.

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

[0.7.0]: https://github.com/gapmiss/chestnut/compare/v0.6.2...v0.7.0
[0.6.2]: https://github.com/gapmiss/chestnut/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/gapmiss/chestnut/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/gapmiss/chestnut/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/gapmiss/chestnut/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/gapmiss/chestnut/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/gapmiss/chestnut/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/gapmiss/chestnut/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/gapmiss/chestnut/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/gapmiss/chestnut/releases/tag/v0.1.0
