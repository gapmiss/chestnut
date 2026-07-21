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
| `save` | Saves stdout as a file to a vault (filename from the first line or "untitled.md"). |
| `clipboard` | Copies stdout to the system clipboard. |
| `notify` | Shows stdout as a notice bubble above the pet. |
| `structured` | Parses stdout as a JSON envelope for full control (see below). |

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
| `filename` | no | Filename for `save` action (default: `untitled.md`) |
| `vault` | no | Vault hint for `save`: `"ask"` (picker), `"pinned"`, `"last"`, or a vault path |
| `folder` | no | Subfolder within the vault for `save` (created if needed) |
| `notify` | no | Subtitle text for the notice bubble |

Unknown fields are ignored (forward-compat).

## Error handling

- **Non-zero exit** shows the first line of stderr as an error bubble.
- **Timeout** shows "Plugin timed out" as an error bubble.
- **Bad structured output** (invalid JSON or missing `action`) shows an error.

Errors never trigger the gulp animation.

## Multiple plugins

When several plugins accept the same input type, Chestnut shows a picker
palette (type to filter, arrows to navigate, enter to run). If only one
matches, it runs immediately.

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

## Example plugin

See [`Examples/plugins/yt-transcript/`](Examples/plugins/yt-transcript/) for a
complete plugin that downloads YouTube transcripts via `yt-dlp` and saves them
as formatted vault notes with timestamped, clickable transcript lines.

To install it:

```bash
cp -r Examples/plugins/yt-transcript ~/.config/chestnut/plugins/
```

Requires `yt-dlp` (`brew install yt-dlp`).
