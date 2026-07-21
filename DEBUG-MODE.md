# Debug Mode — Implementation Plan

## Overview

A single `"debug": true` flag in `config.json` that enables diagnostic logging
to `~/Library/Logs/Chestnut/chestnut.log`. Zero cost when off. No UI — toggled
by hand-editing config, same as `petPalette` and `customThemes`.

## Config

Add `var debug = false` to `Config`. Decoded with `decodeIfPresent`, defaults
to `false`. Not written back by `save()` — strip it from the encoder output so
routine saves (window drags, opacity changes) don't pollute config with
`"debug": false` on every user's machine. Hand-edited `true` survives because
`save()` round-trips through Codable and the key is declared.

## DebugLog module

New file: `Sources/Chestnut/Support/DebugLog.swift`.

```
@MainActor
enum DebugLog {
    private(set) static var enabled = false

    static func configure(enabled: Bool)  // called once from AppDelegate
    static func log(_ message: String)    // no-op when disabled
}
```

- Log file: `~/Library/Logs/Chestnut/chestnut.log`
- Append-only, opened once at configure time.
- Rotate on launch: if existing log exceeds 1 MB, move to `chestnut.log.1`
  (keep only one previous). No log4j, no levels, no categories.
- Each line: ISO 8601 timestamp + message. No structured format needed.

## Instrumentation points

These are the decision points worth logging — the places where "why did it do
that?" is hard to answer after the fact.

### Drag-and-drop classification (PetView / PluginDispatch)

- All pasteboard types present on `draggingEntered` (the diagnostic we just
  removed — make it permanent behind the flag).
- Which branch was taken: native file URL, Electron file:// from public.url,
  obsidian:// resolution, plugin dispatch classification, or fallback.
- For obsidian:// URLs: vault name, resolved vault path (or "not found"),
  resolved file path (or "not found").

### Plugin system

- Plugin registry: discovered plugins on startup and hot-reload (name + path).
- Plugin dispatch: input type classified, plugins matched, plugin selected.
- Plugin runner: script invoked, exit code, output mode, timeout hit.
- Plugin output: structured envelope parse result, attachment resolution.

### Courier

- Source file, destination vault, resolved target path.
- Conflict resolution: suffix applied, attachment renames.
- Journal entry recorded.

### Capture

- Target vault, daily note path resolution (plugin config vs. Chestnut native
  vs. inbox fallback).
- Append vs. create.

### Vault registry

- Reload events: vault count, open count, any vaults added/removed since last
  reload.

### Config

- Load: source path, parse success/failure, backup created.
- Theme validation: custom themes registered, invalid themes skipped.

### Hotkeys

- Registration success/failure per binding.
- Key event received, action dispatched.

## Activation

```json
// ~/.config/chestnut/config.json  (actually ~/Library/Application Support/Chestnut/config.json)
{
  "debug": true
}
```

Restart required (log file handle opened at launch). Log location printed to
stderr on launch when debug is on, so `open -a Chestnut` from Terminal shows
where to look.

## What this is NOT

- No log viewer UI.
- No runtime toggle (restart required).
- No log levels / categories / filtering.
- No network, no crash reporting, no telemetry.
- No performance overhead when off — `DebugLog.log` is an early-return no-op.

## Files touched

| File | Change |
|------|--------|
| `Support/Config.swift` | Add `var debug = false`, decode with `decodeIfPresent` |
| `Support/DebugLog.swift` | **New** — gating function + file writer |
| `AppDelegate.swift` | Call `DebugLog.configure(enabled: config.debug)` at launch |
| `Pet/PetWindow.swift` | Log pasteboard types + routing decision in `draggingEntered` / `performDragOperation` |
| `Plugins/PluginDispatch.swift` | Log classification result |
| `Plugins/PluginRegistry.swift` | Log discovery + hot-reload |
| `Plugins/PluginRunner.swift` | Log invocation, exit code, output parse |
| `Actions/Courier.swift` | Log source, dest, conflicts |
| `Actions/Capture.swift` | Log target vault, note path, mode |
| `Vaults/VaultRegistry.swift` | Log reload diffs |
| `Support/Hotkeys.swift` | Log registration + dispatch |
