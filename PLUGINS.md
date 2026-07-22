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
  "accepts": ["text", "url", "image", "file", "pdf"],
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
| `timeout` | no | Maximum seconds before the plugin is killed. Default: `10`. |

### Input types

| Type | Trigger | What the plugin receives |
|------|---------|------------------------|
| `text` | Plain text drop or paste | Text on stdin |
| `url` | URL drop or paste | URL string on stdin |
| `image` | Image drop or paste (png, jpg, gif, heic, webp, tiff, svg) | File path in `CHESTNUT_FILE_PATH` |
| `file` | Non-markdown file drop | File path in `CHESTNUT_FILE_PATH` |
| `pdf` | PDF file drop | File path in `CHESTNUT_FILE_PATH` |
| `any` | Matches all of the above | Depends on actual content |

Unknown type names in `accepts` are silently ignored (forward-compat). At least
one recognized type is required.

### Output modes

| Mode | Behavior |
|------|----------|
| `capture` | Opens the capture panel pre-filled with stdout as draft text. |
| `save` | Saves stdout as a file to a vault (filename from the first line or "Untitled.md"). |
| `clipboard` | Copies stdout to the system clipboard. |
| `notify` | Shows stdout as a notice bubble above the pet. |
| `structured` | Parses stdout as a JSON envelope for full control (see below). |

### Limits

- **Stdout** is capped at **1 MB**. Output beyond that is silently truncated.
  For `structured` mode, truncation breaks the JSON — the error message will
  note that stdout was truncated.
- **Timeout** defaults to 10 seconds (configurable via `timeout` in the
  manifest). On timeout the plugin and any child processes are terminated
  (SIGTERM, then SIGKILL after 1 s).

## Environment variables

Scripts receive context through environment variables:

| Variable | Description |
|----------|-------------|
| `CHESTNUT_INPUT_TYPE` | The matched type: `text`, `url`, `image`, `file`, or `pdf` |
| `CHESTNUT_FILE_PATH` | Absolute path for `image`/`file`/`pdf` inputs; empty for `text`/`url` |
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
| `filename` | no | Filename for `save` action (default: `Untitled.md`) |
| `vault` | no | Vault hint for `save`: `"ask"` (picker), `"pinned"`, `"last"`, or a vault path |
| `folder` | no | Subfolder within the vault for `save` (created if needed) |
| `notify` | no | Subtitle text for the notice bubble |
| `attachments` | no | Array of files to copy alongside the note (see below) |

Unknown fields are ignored (forward-compat).

### Attachments

When `action` is `"save"`, the `attachments` array lets a plugin save
additional files (images, PDFs, etc.) into the same vault folder as the note:

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
| `filename` | Destination filename inside the vault folder |

Each attachment is copied (not moved) into the same directory as the note.
Name conflicts get Obsidian-style suffixes, same as notes.

## Error handling

- **Non-zero exit** shows the first line of stderr as an error bubble.
- **Timeout** shows "Plugin timed out" as an error bubble.
- **Bad structured output** (invalid JSON or missing `action`) shows an error.

Errors never trigger the gulp animation.

## Debugging

Set `"debug": true` in `~/Library/Application Support/Chestnut/config.json`
to enable a session log at `~/Library/Logs/Chestnut/chestnut.log`. The log
records plugin dispatch decisions, input classification, and run results.

**Privacy note:** with debug enabled, clipboard text and dropped-file paths
are written to the log. Disable it when you're done troubleshooting.

## Multiple plugins

When several plugins accept the same input type, Chestnut shows a picker
palette (type to filter, arrows to navigate, enter to run). If only one
matches, it runs immediately.

## Viewing installed plugins

Right-click the pet → **Plugins** to see all installed plugins with their
descriptions. The submenu also includes **Open Plugins Folder** to reveal the
plugins directory in Finder.

## Hot reload

Chestnut watches `~/.config/chestnut/plugins/` via FSEvents. Adding, removing,
or modifying a plugin directory is detected automatically. No restart needed.

## Drag-and-drop behavior

The drag-and-drop flow with plugins installed:

1. **All `.md` files** go to the courier (existing behavior, unchanged).
2. **Other content** (non-.md files, URLs, images, text) is classified and
   matched against installed plugins.
3. **No matching plugin** for non-.md file drops falls back to the courier.

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

To install any example:

```bash
cp -r Examples/plugins/<name> ~/.config/chestnut/plugins/
```

`yt-transcript` requires `yt-dlp` (`brew install yt-dlp`). All others use
only macOS built-in tools.

**Note:** Chestnut itself makes no network calls, but plugins run as
independent processes and may fetch data (e.g. `url-bookmark` and
`yt-transcript` download web content).
