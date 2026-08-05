# Plugins

Chestnut's plugin system lets you extend drag-and-drop and the paste hotkey
with shell scripts that transform dropped or pasted content into vault notes.

Plugins are zero-cost when none are installed: courier and all existing features
work identically.

## Quick start

```bash
mkdir -p ~/.config/chestnut/plugins/hello
cat > ~/.config/chestnut/plugins/hello/manifest.json << 'EOF'
{
  "api": 1,
  "name": "hello",
  "description": "Echo dropped text into a capture",
  "accepts": ["text"],
  "output": "capture",
  "script": "hello.sh"
}
EOF
printf '#!/bin/bash\necho "Received: $(cat)"' > ~/.config/chestnut/plugins/hello/hello.sh
chmod +x ~/.config/chestnut/plugins/hello/hello.sh
```

Chestnut detects new plugins automatically (no restart needed). Drop a text
selection onto the pet or press the paste hotkey (default `control+option+c`)
with text on the clipboard. The capture panel opens pre-filled with
"Received: {text}".

## Plugin structure

Each plugin lives in its own directory under `~/.config/chestnut/plugins/`:

```
~/.config/chestnut/plugins/
  my-plugin/
    manifest.json     # required
    my-script.sh      # must be executable (chmod +x)
    lib/              # optional supporting files
```

## Manifest reference

`manifest.json` declares what the plugin accepts and how Chestnut handles its
output.

```json
{
  "api": 1,
  "name": "my-plugin",
  "description": "What this plugin does",
  "accepts": ["text", "url", "image", "file", "pdf", "folder"],
  "output": "capture",
  "script": "my-script.sh",
  "timeout": 10
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `api` | yes | Must be `1`. Plugins declaring a higher version won't load. |
| `name` | yes | Unique identifier. If two plugins share a name, only one loads. |
| `description` | no | Shown in the picker when multiple plugins match. |
| `accepts` | yes | Array of input types this plugin handles. |
| `output` | yes | How Chestnut interprets stdout (see Output modes). |
| `script` | yes | Filename of the executable, relative to the plugin directory. |
| `timeout` | no | Maximum seconds before the plugin is killed. Default: `10`, clamped to 1–14400 (4 hours). |
| `stream` | no | `true` makes each line of stdout a complete JSON envelope, so the plugin can report progress while it runs. Requires `"output": "structured"`. Default: `false` (see Long-running plugins). |

### Input types

| Type | Trigger | What the plugin receives |
|------|---------|------------------------|
| `text` | Plain text drop or paste | Text on stdin |
| `url` | URL drop or paste | URL string on stdin |
| `image` | Image drop or paste (png, jpg, gif, heic, webp, tiff, svg) | File path in `CHESTNUT_FILE_PATH` |
| `file` | Non-markdown file drop | File path in `CHESTNUT_FILE_PATH` |
| `pdf` | PDF file drop | File path in `CHESTNUT_FILE_PATH` |
| `folder` | Directory drop or paste | Directory path in `CHESTNUT_FILE_PATH` |
| `any` | Matches all of the above | Depends on actual content |

Unknown type names in `accepts` are silently ignored (forward-compat). At least
one recognized type is required.

A *pasted* image (as opposed to a dropped file) is written to a temp file first,
and `CHESTNUT_FILE_PATH` points at that. A screenshot pasteboard carries both
PNG and TIFF; Chestnut writes the PNG, since Obsidian renders no TIFF. The
extension always describes the actual bytes, so trust the path's suffix.

Plugins receive single-item drops only: dropping several files (or folders) at
once is a courier delivery, all of it. Drop an item on its own to offer it to
a plugin.

### Output modes

| Mode | Behavior |
|------|----------|
| `capture` | Opens the capture panel pre-filled with stdout as draft text. |
| `save` | Saves stdout as a file to a vault (filename from the first line or "Untitled.md"). |
| `clipboard` | Copies stdout to the system clipboard. |
| `notify` | Shows stdout as a notice bubble above the pet. |
| `structured` | Parses stdout as a JSON envelope for full control (see below). |

### Undoing a save

`save` is the only mode that writes files without the user seeing them first, so every save is journaled and the right-click menu gains an **Undo Last Plugin Save** row naming your plugin. Undo trashes the note and any attachments the save copied, following the vault's own **Deleted files** setting: a vault set to move deletions to its `.trash` folder gets them there, anything else gets the macOS Trash. A vault set to delete permanently is the one exception — those files go to the macOS Trash too, because an undo takes back something Chestnut did rather than something the user chose to delete. Nothing is ever deleted outright, and nothing pre-existing is ever touched: a save that would land on an occupied name gets an Obsidian-style suffix instead of overwriting, so every path undo touches is one Chestnut created.

Undo refuses if the note has changed size since the save, because by then the path may belong to a file Chestnut never wrote. You get an alert offering to discard the journal entry instead.

This covers what Chestnut writes on your plugin's behalf. It cannot cover what your script does itself — files your script copies, moves or deletes directly are outside the journal and stay done. If your plugin makes its own filesystem changes, say so in its `description`.

`capture` output is undoable too, once submitted, through **Undo Last Capture**. `clipboard` and `notify` write nothing.

### Limits

- **Stdout** is capped at **1 MB** for the whole run. Output beyond that is
  silently truncated. For `structured` mode, truncation breaks the JSON, and
  the error message says that stdout was truncated.

  This matters more the longer your plugin runs. A ten-second plugin never
  approaches 1 MB; one that prints a progress line every second for an hour
  does, and the envelope it prints at the end is the part that gets cut off.
  **A long-running plugin should not print continuously.** If you want progress
  messages, set `"stream": true`, which caps each line (64 KB) instead of the
  run, so nothing you print early can crowd out what you print at the end.
- **Timeout** defaults to 10 seconds (configurable via `timeout` in the
  manifest, clamped to 1–14400; a value outside that range is logged and
  adjusted). On timeout the plugin and any child processes are terminated
  (SIGTERM, then SIGKILL after 1 s). Omitting `timeout` gives you 10 seconds;
  `timeout: 0` is clamped up to 1 second and never means "no timeout" — there
  is no way to run without one.

## Environment variables

Scripts receive context through environment variables:

| Variable | Description |
|----------|-------------|
| `CHESTNUT_INPUT_TYPE` | The matched type: `text`, `url`, `image`, `file`, `pdf`, or `folder` |
| `CHESTNUT_FILE_PATH` | Absolute path for `image`/`file`/`pdf`/`folder` inputs; empty for `text`/`url` |
| `CHESTNUT_SOURCE_APP` | Bundle identifier of the frontmost app (e.g. `com.apple.Safari`) |
| `CHESTNUT_TIMESTAMP` | ISO 8601 timestamp of the drop/paste event |
| `CHESTNUT_PLUGIN_DIR` | Absolute path to the plugin's directory |
| `PATH` | Includes `/opt/homebrew/bin` and `/usr/local/bin` |
| `HOME` | User's home directory |

**stdin** carries the content for `text` and `url` inputs. For other types,
stdin is `/dev/null`; use `CHESTNUT_FILE_PATH` instead.

## Structured output (JSON envelope)

When `output` is `"structured"`, the script prints a JSON object to stdout
with full control over what Chestnut does:

```json
{
  "action": "save",
  "content": "# My Note\n\nHello world\n",
  "filename": "my-note.md",
  "vault": "ask",
  "folder": "inbox",
  "notify": "Note saved successfully"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `action` | yes | One of `capture`, `save`, `clipboard`, `notify` |
| `content` | no | The text content (note body, clipboard text, or notice title) |
| `filename` | no | Filename for `save` action (default: `Untitled.md`). Sanitized: `/`, `\` and `:` become `-`, capped at 200 characters, trimmed, and `.md` appended if missing. Use `folder` for subfolders. |
| `vault` | no | Vault hint for `save`: `"ask"` (picker), `"pinned"`, `"last"`, or a vault path |
| `folder` | no | Subfolder within the vault for `save` (created if needed) |
| `notify` | no | Subtitle text for the notice bubble |
| `attachments` | no | Array of files to copy alongside the note (see below) |

Unknown fields are ignored (forward-compat).

### Attachments

When `action` is `"save"` or `"capture"`, the `attachments` array lets a
plugin save additional files (images, PDFs, etc.) into the vault:

```json
{
  "action": "save",
  "content": "# OCR\n\n![[scan.png]]\n\nExtracted text...",
  "filename": "ocr-note.md",
  "attachments": [
    { "source": "/path/to/original.png", "filename": "scan.png" }
  ]
}
```

| Field | Description |
|-------|-------------|
| `source` | Absolute path to the file to copy |
| `filename` | Destination filename. Sanitized as above, but no `.md` is appended |

Attachments land in the vault's configured attachment folder, read from
`attachmentFolderPath` in `.obsidian/app.json` and falling back to the vault
root when that is unset. This is true for both `save` and `capture`, and the
`folder` field does not move them: `folder` places the note, its attachments
still go to the attachment folder. For `capture`, only attachments the
submitted note actually refers to by filename are copied, and the copy happens
when the user submits. Name conflicts get Obsidian-style suffixes in every
case.

## Long-running plugins

Some plugins take minutes or hours: transcribing a recording, OCR-ing a long
scan, converting a folder of documents, running a local model over a PDF. Set
`timeout` to cover the worst case (up to 4 hours) and the run is supervised the
whole time.

While a plugin runs:

- The pet chews. It keeps chewing until the *last* run finishes, so two plugins
  at once behave the way you would expect.
- Right-click the pet → **Running Plugins** lists every live run by name, with
  how long it has been going. The submenu is absent when nothing is running.
- Clicking a run stops it. The script and anything it started are sent SIGTERM,
  then SIGKILL a second later, and the notice says the run was stopped rather
  than that it timed out.
- Quitting Chestnut from the menu stops running plugins the same way. This is
  best-effort, and only covers a real quit: a crash, a force quit from Activity
  Monitor, or `pkill`/`kill` from a terminal all leave your script running.
  Nothing macOS offers can change that.

A plugin that finishes more than a minute after it started does not steal focus.
Past that point the user has moved on to another application, and anything that
opens a panel there is an interruption over someone else's work. So a late
result waits rather than appearing:

- An `action: "capture"` parks its draft. The **Capture…** row badges itself
  `draft`, and the draft is there the next time that row is opened.
- An `action: "save"` that has to ask which vault parks too, rather than opening
  the vault picker. A row reading **Save <plugin>'s Output…** appears in the
  right-click menu and opens the picker when the user is ready. Two plugins
  waiting at once get a row each.

Both also show a notice when they park, but the notice is only a shortcut — it
fades like any other, and the menu is what holds the result.

A `save` whose envelope names a `vault` is unaffected by any of this. It needs
no picker, so it lands straight away however late it finishes.

### Reporting progress

Set `"stream": true` (with `"output": "structured"`) and print **one complete
JSON envelope per line**:

```bash
#!/bin/bash
total=50
for i in $(seq $total); do
  process_one "$i"
  printf '{"action":"notify","notify":"%d of %d"}\n' "$i" "$total"
done
printf '{"action":"save","filename":"result.md","content":"..."}\n'
```

Each `notify` line updates the notice bubble as it arrives. Rules:

- **Only `notify` happens while the plugin runs.** Every other action — `save`,
  `clipboard`, `capture` — is held until your script exits 0. **A plugin that
  fails still writes nothing**, exactly as before: print an envelope and then
  `exit 1`, and nothing lands.
- **Print one non-`notify` envelope.** If you print several, the last one wins;
  the others are discarded.
- **A line that is not valid JSON is skipped**, logged, and the run continues.
  A stray `echo` will not lose you an hour of work.
- **Each line is capped at 64 KB.** A longer line is cut, which makes it invalid
  JSON, so it is skipped like any other bad line.
- Envelopes must be one per line. Do not pretty-print them — that is exactly
  what `stream` changes, and it is why `stream` is opt-in.

Without `"stream": true`, nothing changes: the whole of stdout is one envelope,
pretty-printed or not.

## Error handling

- **Non-zero exit** shows the first line of stderr as an error bubble.
- **Timeout** shows "Plugin timed out" as an error bubble.
- **Cancelled** (from **Running Plugins**) shows "Plugin stopped" — it is not
  reported as an error, because you asked for it.
- **Bad structured output** (invalid JSON or missing `action`) shows an error.

Errors never trigger the gulp animation.

## Debugging

Set `"debug": true` in `~/Library/Application Support/Chestnut/config.json`
to enable a session log at `~/Library/Logs/Chestnut/chestnut.log`. The log
records plugin dispatch decisions, input classification, and run results.

**Privacy note:** with debug enabled, file paths (dropped files, notes,
vaults) and your plugins' stderr output are written to the log. Clipboard
*content* is never logged, only its type and length. Disable debug when
you're done troubleshooting.

## Multiple plugins

When several plugins accept the same input type, Chestnut shows a picker
palette (type to filter, arrows to navigate, enter to run). On a paste
(⌃⌥C), a single match runs immediately. On a drop the picker appears even
for a single match, because a dropped file is always something the courier
could deliver instead; see below.

## Viewing installed plugins

Right-click the pet → **Plugins** to see all installed plugins with their
descriptions. The submenu also includes **Open Plugins Folder** to reveal the
plugins directory in Finder.

## Hot reload

Chestnut watches `~/.config/chestnut/plugins/` via FSEvents. Adding, removing,
or modifying a plugin directory is detected automatically. No restart needed.

## Drag-and-drop behavior

**A plugin never takes a dropped file away from the courier.** Everything
dropped on Chestnut is a file on disk, so the courier can always deliver it.
When a plugin matches as well, Chestnut asks rather than choosing:

1. **All `.md` files** go to the courier, no picker.
2. **Several items dropped together** are a courier delivery, all of it, even
   when a plugin would match one of them.
3. **A single item no plugin matches** goes straight to the courier, no picker.
4. **A single item a plugin matches** opens the picker, listing the matching
   plugins and a **Deliver to a vault** row. The plugin is preselected, so ⏎
   runs it and ↓ ⏎ delivers instead. This covers folders too: installing a
   `folder` plugin adds a choice, it does not remove folder delivery.

Through 0.6.2 a matching plugin claimed the drop outright, and installing a
plugin silently removed the courier gesture for that file type. That is gone.

Paste (⌃⌥C) is unaffected: a pasted image is not a file the courier can
deliver, so a single match still runs immediately.

While a plugin runs, Chestnut shows a chewing animation. On success, it
performs the gulp.

## Paste hotkey

Default: `control+option+c`. Reads the system clipboard, classifies its
content, and dispatches to matching plugins. Configure in the config file:

```json
{
  "hotkeys": {
    "paste": "control+option+c"
  }
}
```

## Example plugins

The [`Examples/plugins/`](Examples/plugins/) directory contains ready-to-use
plugins in different languages, covering every input type and output mode:

| Plugin | Language | Input | Output | Description |
|--------|----------|-------|--------|-------------|
| [`yt-transcript`](Examples/plugins/yt-transcript/) | Python | `url` | `structured` (save) | YouTube transcript to vault note via `yt-dlp` |
| [`img-ocr`](Examples/plugins/img-ocr/) | Swift | `image` | `structured` (save + attachment) | OCR via macOS Vision; saves text note + image |
| [`img-info`](Examples/plugins/img-info/) | Bash | `image` | `notify` | Show image dimensions and file size |
| [`url-bookmark`](Examples/plugins/url-bookmark/) | Python | `url` | `structured` (save) | Bookmark note with page title and description |
| [`code-snippet`](Examples/plugins/code-snippet/) | Ruby | `text` | `structured` (save) | Auto-detect language, save fenced code note |
| [`pdf-extract`](Examples/plugins/pdf-extract/) | Swift | `pdf` | `structured` (save) | Extract text from PDF via `textutil` |
| [`word-count`](Examples/plugins/word-count/) | Perl | `text` | `notify` | Word count and reading time bubble |
| [`clipboard-clean`](Examples/plugins/clipboard-clean/) | Zsh | `text` | `clipboard` | Strip smart quotes and whitespace |
| [`folder-index`](Examples/plugins/folder-index/) | Bash | `folder` | `structured` (save + attachments) | Index note with all files as attachments |
| [`img-clip-daily`](Examples/plugins/img-clip-daily/) | Bash | `image` | `structured` (capture + attachment) | Save clipboard image to today's daily note |
| [`img-clip-note`](Examples/plugins/img-clip-note/) | Bash | `image` | `structured` (save + attachment) | Save clipboard image as a new note |

To install any example:

```bash
cp -r Examples/plugins/<name> ~/.config/chestnut/plugins/
```

`yt-transcript` requires `yt-dlp` (`brew install yt-dlp`). All others use
only macOS built-in tools.

**Note:** Chestnut itself makes no network calls, but plugins run as
independent processes and may fetch data (e.g. `url-bookmark` and
`yt-transcript` download web content).
