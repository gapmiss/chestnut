# Architecture

Design decisions that span files. Anything that lives inside one type is documented at that type — this file covers only what no single source file owns, plus the policies that bind several together.

For the rules that must never be broken, see the Hard invariants section of `CLAUDE.md`. For the plugin author's view, see `PLUGINS.md`.

## Layers

| Layer | Technology | Role |
|---|---|---|
| Windows | AppKit | Borderless, transparent, always-on-top pet window; right-click menu; drag-drop |
| Pet | SpriteKit | Sprite animation from hand-coded frame matrices |
| Panels | SwiftUI | Vault palette, capture panel, notice bubble, plugin picker |

AppKit stays a thin host. Panels are `NSPanel`-hosted and never take key focus from other apps (`.nonactivatingPanel`), so Chestnut can act on a vault while the user keeps typing somewhere else.

Sprites are hand-coded string matrices mapped through palette colors into `SKTexture` with `.nearest` filtering. No image assets, no art tools, and `docs/sprites.js` is generated from the same Swift sources by `make site`.

`PetController` is a pure state machine — idle, writing, delivery — and drives animation in `PetScene`. Writing state comes from `VaultWatcher` FSEvents, not from Obsidian.

Steady state is 10fps; 60fps is used only during hop and gulp gestures. Idle CPU is about 3% of one core (measured on 0.5.0 by sampling `ps -o cputime` over 30s and 45s idle windows: 3.8% and 2.4%). `ps -o %cpu` reports a since-launch average, about 2.5%, and is the wrong number to quote.

## Testability: pure logic lives away from AppKit

`PetWindow.swift` and `AppDelegate.swift` are AppKit and outside the check target, so `Checks/main.swift` cannot reach them. Logic worth testing is therefore extracted to types that take injected values instead of touching AppKit globals:

- `PetGeometry` — window size and origin maths, taking `PetScreen` rects rather than `NSScreen`. An unreachable pet is the failure most worth testing. `menuOrigin` lives here for the same reason: a menu positioned off-screen takes Settings, Undo, Reset Position and Quit with it, and it is reached by the keyboard route that exists precisely because the pet may be unreachable.
- `DropRouter` — pure drop routing. Every dropped URL must land in exactly one place; an item silently going nowhere is the failure worth testing.
- `AppState` — size and opacity presets live here, not in `PetWindow`, so checks can reach them.

`Panels/` and `PluginPalette.swift` import SwiftUI and are also outside the target. Where that leaves a rule unasserted, a shared helper is the drift guard instead — `VaultPaletteModel.accessibilityLabel(for:isPinned:)` is spelled once and reused by both the announcement and the row label, so the two cannot disagree.

## Two settings files

Both in `~/Library/Application Support/Chestnut/`:

- **`config.json`** (`Config`) is user-owned and hand-edited: hotkeys, custom themes, capture destination, `debug`.
- **`state.json`** (`AppState`) is app-owned: window position, size, opacity, theme, copy-on-drop, full-screen, `noticeDuration`, `reduceMotion`, pinned vault, last capture vault, `disabledPlugins`.

**The app never writes `config.json`** except `createIfMissing()` on first run, which only fires when no file exists. No other write path exists and none should be added — that invariant is what keeps a window drag from clobbering a hand-edited hotkey. Anything gaining a UI moves to `AppState`.

**No settings migrations.** Both decoders are tolerant: unknown and stale keys are ignored, missing keys take defaults, so a key can move between the files without migration code. Moving one costs the user the value (it reverts to default) but never a broken launch. That trade holds because everything in `AppState` is a menu click away — reconsider only if a value becomes expensive to recreate, or if its loss would be *invisible*. The 0.3 split shipped with a migration; it was deleted in 0.4 rather than carried.

Unparseable files are *moved* to the first free `.bak`/`.bak.N`, never copied over an earlier backup. `CGPoint` encodes as `[x, y]`, not `{"x":…}`.

## The right-click menu

`PetWindow.showMenu` is an assembly list, one builder method per group. Order is actions first, then the pet's identity, then about:

```
Vaults… / Capture…
Undo Last Delivery / Undo Last Capture / Undo Last Plugin Save   (each subtitled with the record it reverses; the third row is hidden until a plugin is installed or a record exists)
Size ▸ / Theme ▸ / Settings ▸ / Plugins ▸
Check for Updates… (version + ↗ in one badge) / Support Chestnut
Quit
```

Size and Theme stay top-level deliberately; everything set-once lives in Settings ▸, which is flat: Opacity ▸, Notice Bubble ▸, then Reduce Motion / Copy on Drop / Show in Full Screen / Launch at Login, then Reset Position / Edit Configuration….

**The menu reaches a third level in exactly two places** — Settings ▸ Opacity ▸ and Settings ▸ Notice Bubble ▸ — and nowhere else. Both were sliders. A slider is an `NSMenuItem.view`, and **AppKit skips view items in a menu's key loop**, so neither value could be set without a mouse. That mattered most for opacity: at its floor the sprite is nearly invisible, and the only control that restored it was a slider you had to drag on a pet you could no longer see. Discrete preset items are keyboard-reachable and are one control per value rather than a slider shadowed by a stand-in. **Do not reintroduce a view-based row** without solving this.

## Keyboard reachability

⌃⌥Space (capture), ⌃⌥V (hopper), ⌃⌥C (paste, plugin dispatch from clipboard), ⌃⌥O (notice action, registered only while an actionable bubble is visible), ⌃⌥M (menu). All configurable in `config.json`.

**The menu binding is load-bearing, not a convenience.** `canBecomeKey` is false so no menu key equivalent ever fires, `hitTest` limits the right-click to opaque sprite pixels, and an `LSUIElement` app is absent from Force Quit. Without ⌃⌥M there is no keyboard route to Settings, Undo, or Quit. That is why a failed menu binding raises a one-time notice naming the binding and pointing at `config.json`, while the other four only log.

Menu key equivalents come from the same `HotkeySpec` parse that backs Carbon registration, so the menu cannot advertise a key no hotkey backs.

**VoiceOver claims all five, including the load-bearing one.** Control-Option *is* VoiceOver's modifier: ⌃⌥V is speech verbosity, ⌃⌥M is the menu bar, and VoiceOver wins the keystroke. With it running there is no hotkey route into Chestnut at all. The pet's own right-click still works, and reads correctly once open. Established by a ⌘F5 pass, not by reasoning.

**The answer is rebinding, not new defaults.** `README.md` documents a `control+shift+…` set, and `make check` parses those five strings *out of the README* so the example cannot drift into one that fails at launch. Changing the shipped defaults would move every existing user's shortcuts to solve a case rebinding already solves.

Weigh further VoiceOver work against this. Row-announcement polish is not what stands between a VoiceOver user and this app; the ⌃⌥ collision is.

## Concurrency

`Courier` and `Capture` run off the main actor (`Task.detached`). For the courier the reason is strong: a cross-volume `place()` is a full byte copy, `resolve()` walks the whole source vault once per unresolved reference, and `contentsEqual` byte-compares every deduped file. On the main actor, any of the three freezes the pet, the menu and every hotkey until it finishes. The chewing pose is held for the duration so the wait reads as work.

Both types hold no state so they stay `Sendable` — `Courier`'s `fm` is *computed, not stored*, the same move `Capture` made.

## Journal caps

Journals are capped by `JournalLimits` — 20 records and 1 MB — and rewritten atomically on every append. Both limits are load-bearing: a courier record can carry a whole note body in `NoteRewrite.original`.

A record that blows the byte cap on its own is **shed, not dropped**. `trimmed` keeps a lone record at any size, so the ceiling is enforced in `append` before the line is ever written. What a record gives up differs by type, and that asymmetry is the design — see the `JournalShedding` tripwire in `CLAUDE.md`.

## Where undone files go

All three undos — courier copy, capture, plugin save — remove files through one type, `VaultTrash`, rather than calling `FileManager.trashItem` themselves. It reads `trashOption` from the destination vault's `.obsidian/app.json` and follows it: `"system"` (or absent) is the macOS Trash, `"local"` is `<vault>/.trash/`, which is what Obsidian's own restore-from-trash reads.

The vault is found by walking up from the file until a directory holds `.obsidian/`, nearest first, **not** taken from the record. `CourierOperation` has no vault field, and adding one would leave every already-journaled record unable to name its vault. `CaptureRecord` and `PluginSaveRecord` do carry `vaultPath` and still go through the walk, so there is one answer to the question and the three undos cannot drift.

One instance per undo call, memoizing the option per vault root, because a single reversal can touch a note and fifty attachments. Never shared across calls: the user can change the setting in Obsidian between two undos.

`"none"` is read faithfully and then clamped to the system Trash — the one deliberate departure from matching Obsidian, tripwired in `CLAUDE.md`. The `obsidian` CLI is not involved; its `delete` ignores `trashOption` outright.

## Window behaviour and login

- **Pinned vault:** one vault sorts first everywhere (hopper, courier, capture), toggled with the pin icon or ⌘P.
- **Launch at login:** `SMAppService.mainApp`, toggled in Settings ▸.
- **Full-screen visibility:** `collectionBehavior`-based, toggled in Settings ▸. The window is `orderOut`/`orderFront`-cycled on toggle to force the window server to re-evaluate.

## Contention: one panel at a time

Plugin runs and the courier compete for the same one-at-a-time surfaces. `presentPalette` dismisses whatever palette and notice are up, so a plugin picker or a `save` plugin's vault palette opening beside the courier's destination palette clobbers one or the other.

That is why the picker's courier row dismisses *before* calling `beginDelivery`, as `runPlugin` does — otherwise the dismissed panel's `onClose` clears `palette` out from under the destination palette that just opened.

## Drop routing

The rules, in the order they apply:

1. A **pathless Obsidian drag** (a folder dragged from Obsidian's file explorer) is diverted to a notice, *before* `PluginDispatch.classifyDrag`.
2. **`.md` always rides the courier**, unasked.
3. **Multi-item drops ride the courier wholesale**, even when a plugin would match the first item — plugin dispatch is single-item only.
4. A single item **no plugin matches** goes straight to the courier, unasked.
5. A single item **a plugin also matches** returns `.ask`, and the picker gains a "Deliver to a vault" row.

**A plugin never takes a dropped file away from the courier.** Through 0.6.2 a matching plugin claimed the item outright, so installing a `folder` plugin removed folder delivery — silently, permanently, with the app's primary feature outranked by a shell script. The plugin row is preselected, so ⏎ reproduces pre-0.7 behaviour and the prompt is an interception rather than a reversal.

No opt-out ships. A **modifier key** at drop time and an **optional per-type manifest flag** were both considered and deferred; prefer either to a global toggle, which hides the courier across every type and recreates the problem as a setting.

A resolved `obsidian://` link feeds the same `DropRouter.route` call as a Finder drop — there is no Obsidian branch left in `performDragOperation`, only a choice of which list of URLs to route. The old bypass existed because plugins shadowed the courier; that fix landed, so the bypass had nothing left to work around. Known cost: a single Obsidian attachment with a matching plugin enabled now gets a picker where it used to go straight to the courier. Accepted, because the courier row is one ↓ away.

## Vault containment

A *lexical* standardized-path prefix check, in two variants, and the vault root is the difference:

- `Courier.isContained(_:inVault:)` tests `hasPrefix(vaultPath + "/")`, so the root itself fails it. Correct for a **file**, since nothing is ever written *at* the root path.
- `Courier.isContainedDirectory(_:inVault:)` accepts the root, because that is where a plugin `save` with no `folder` lands and where `attachmentFolder(of:)` falls back when `attachmentFolderPath` is unset.

Collapsing the two is the obvious simplification and refuses every ordinary plugin save. `make check` pins the distinction.

`savePluginOutput` checks **both** the directories it creates and the files it writes: checking only the note let an escaping `folder` pair with a `filename` that walked back in, so the note landed inside the vault while `createDirectory` made the escaped folder anyway.

The courier does not call either and does not need to — `deliverNote` builds destinations as `dir.appendingPathComponent(source.lastPathComponent)`, and a `lastPathComponent` cannot contain a `/`, so containment is structural.

One hand-inlined copy of the predicate remains, in `attachmentFolder(of:)`, left that way deliberately: it applies the *file* spelling to a directory and falls back to the vault root whenever the check fails, so swapping in `isContainedDirectory` would quietly change where an `attachmentFolderPath` like `.obsidian/../att` resolves.

## The website mirrors the app by hand

`docs/` is hand-written HTML/CSS/vanilla JS, deployed via GitHub Pages from the `docs` folder on `main`. No build step, no image assets.

The hero chestnut is a `<canvas>` driven by the app's real frame data exported to `docs/sprites.js` by `make site`, and `make check` fails if it drifts from the Swift sources. **Everything else is a hand copy and nothing checks it agrees** — the right-click menu (`renderMenu`), the palette sizing behaviour (`openPalette`), Reduce Motion against `prefers-reduced-motion`, and the Vault Hopper, Quick Capture and Note Courier demos. Reminder comments sit at the four Swift call sites; change them together.

Site copy conventions: the pet is "Chestnut", never "the chestnut"; when a generic noun is needed, "a pixel-art treasure chest creature". **No em-dashes in site copy** — use commas, colons, or separate sentences. Code comments in `docs/*.js` and `docs/*.css` are exempt.

## Distribution

Not notarized. Users clear Gatekeeper via right-click → Open (pre-macOS 15), System Settings → "Open Anyway" (macOS 15+), or `xattr -dr com.apple.quarantine`. Notarization is undecided. See `RELEASING.md` for the release process.

**A `brew upgrade` does not re-block the app, and the quarantine attribute being present is not evidence that it will.** Homebrew quarantines every cask download, so `com.apple.quarantine` is re-stamped at each upgrade with a fresh timestamp — on 0.6.1 it was written five seconds before the bundle landed. That does not revoke the approval the user already gave: the flags carry the approved bit, and no new prompt appears.

`spctl -a -vv` reports `rejected` for this app and always will — it is ad-hoc signed, not notarized, which is the whole point. That verdict describes the signature, not what happens when the user double-clicks, so it is not a Gatekeeper prediction either. **Neither signal justifies telling the maintainer to run `xattr -dr` after an upgrade**; they have corrected this more than once.

The README, `docs/guide.html` and the Homebrew cask's `caveats` all say a later upgrade "may ask again, depending on macOS version". That hedge is aimed at users on machines nobody here can observe, and is deliberately left alone — it is not a licence to repeat the claim about *this* machine.
