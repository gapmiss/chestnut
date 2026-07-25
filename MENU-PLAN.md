# Right-click menu restructure

Plan for flattening the pet's context menu from 18 top-level rows to 11,
and for inlining the two slider rows that currently hide behind
single-item submenus.

Status: **implemented.** Shipping in the same unreleased version as the
notice-duration slider itself, not in a later 0.5.0 — `VERSION` was still
0.3.0 when this landed, so the rows this plan moves had never shipped in their
old positions and the muscle-memory risk in §5 never materialized.

Section 8 records where the build deviated from the plan.

---

## 1. Why

The menu grew one item at a time and nobody re-read it as a whole. Two
separate problems compounded:

**The third group has no theme.** It currently holds two undo *actions*,
two *toggles*, a *submenu*, and a *file-opening action*. Nothing binds
those together, so the eye has to read every row to find anything.

**Frequency is inverted.** The first five rows are appearance settings you
touch once. The things people right-click for — Vaults, Capture, Undo —
sit below them. Size, Theme, Opacity, Notice Duration, Copy on Drop, Show
in Full Screen, Launch at Login and Reset Position are all set-once or
occasional; nine of the eighteen rows are settings.

A third, smaller thing: `Opacity ▸` and `Notice Duration ▸` are submenus
whose entire contents are one slider row. The hover buys nothing.

### Current structure (18 rows, 4 separators, 5 submenus)

```
Size                    ▸
Theme                   ▸
Opacity                 ▸        \ submenu containing exactly one slider
Notice Duration         ▸        / submenu containing exactly one slider
Reset Position
──────────────────
Vaults…               ⌃⌥V
Capture…            ⌃⌥Space
──────────────────
Undo Last Delivery
Undo Last Capture
Copy on Drop                     <- toggle, mixed in with actions
Show in Full Screen              <- toggle, mixed in with actions
Plugins                 ▸
Edit Configuration…              <- action, mixed in with toggles
──────────────────
Chestnut 0.4.0                   <- disabled, informational only
Check for Updates…      ↗
Support Chestnut      ♥ ↗
──────────────────
Launch at Login                  <- setting, orphaned next to Quit
Quit Chestnut
```

---

## 2. Target structure

### Top level (11 rows, 4 separators, 4 submenus)

```
Vaults…                        ⌃⌥V
Capture…                     ⌃⌥Space
────────────────────────
Undo Last Delivery
Undo Last Capture
────────────────────────
Size                             ▸
Theme                            ▸
Settings                         ▸
Plugins                          ▸
────────────────────────
Check for Updates…       0.4.0 ↗
Support Chestnut             ♥ ↗
────────────────────────
Quit Chestnut
```

Actions first, ordered by how often they're used. Settings collapse into
one submenu. Size and Theme stay top-level deliberately: they're the pet's
identity, the most rewarding thing to find early, and burying them costs
more than the two rows save.

### Settings submenu (8 rows, 2 separators, no nesting)

```
Opacity      ──────●───  100%
Notice       ───●──────    8s
────────────────────────
✓ Copy on Drop
  Show in Full Screen
  Launch at Login
────────────────────────
Reset Position
Edit Configuration…
```

Sliders inline, each with a text label and a value readout, so no row in
here opens a further submenu. Three levels of menu never happens.

---

## 3. Decisions already made

**Support Chestnut stays top-level.** Folding it into an About submenu
would save another row, but a funding link you have to hover to find gets
clicked less. Tidiness does not outrank the tip jar. Same reasoning applies
to any future pass over this menu.

**The disabled version row becomes a badge.** `Chestnut 0.4.0` is a dead
row that exists so people can quote a version in bug reports. As a badge on
Check for Updates it stays visible, reads better, and costs nothing.
Note the conflict: that item already carries the `↗` opens-in-browser
badge, and `NSMenuItem` allows only one. Combine into a single string
(`"0.4.0 ↗"`) rather than dropping the affordance.

**Slider icons give way to labels.** The opacity row currently uses a dim
circle and a solid circle at either end to imply direction. Once a row has
a text label on the left and a numeric readout on the right, the icons are
noise. Both rows converge on `Label ──────●─── Value`. This is the one
purely visual change in the plan and the one most likely to want a second
look on screen.

**Reset Position moves into Settings.** It's the recovery path for an
awkwardly placed pet, but if the pet were genuinely unreachable the menu
would be too, so depth costs nothing here. `validatedOrigin` already
guarantees the sprite lands on a screen at launch.

---

## 4. Implementation

### 4.1 `Sources/Chestnut/Pet/PetWindow.swift`

`showMenu(with:in:)` is currently lines 223–392, about 170 lines of
straight-line construction. Restructuring the menu is a good moment to
break it up: the assembly order is the thing being changed, and it should
be readable at a glance.

Extract one builder per group, each returning `NSMenuItem`:

| New method | Contents |
| --- | --- |
| `sizeMenuItem()` | existing Size submenu, lines 228–238 |
| `themeMenuItem()` | existing Theme submenu, lines 240–250 |
| `settingsMenuItem()` | new: the eight rows above |
| `pluginsMenuItem()` | existing Plugins submenu, lines 308–353 |
| `updatesMenuItem()` | Check for Updates… + version badge |

`showMenu` then reduces to an assembly list of roughly 25 lines, which is
the point — the structure becomes visible in the source instead of being
buried in construction detail.

**Slider rows.** `opacitySliderItem()` (line 397) and
`noticeDurationSliderItem()` (line 424) both build
`NSStackView`-in-`NSMenuItem` rows. Unify them behind one helper:

```swift
private func sliderRow(
    label: String,
    value: Double,
    range: ClosedRange<Double>,
    action: Selector,
    readout: @escaping (Double) -> String
) -> (item: NSMenuItem, readout: NSTextField)
```

Layout: label (fixed width, ~56pt, so both sliders align), slider, readout
(fixed width, ~38pt, monospaced digits so `8s` → `30s` and `10%` → `100%`
don't shove the slider sideways). Row width ~230pt; `NSMenu` sizes itself
to its widest item, so both rows should declare the same width.

The existing `menuIcon(_:label:)` helper (line 457) loses both call sites
and should be deleted with them. `secondsLabel(_:)` (line 468) becomes one
of the two `readout` closures; add a percent equivalent for opacity.

Keep `noticeDurationReadout` as a weak stored property and add an
`opacityReadout` alongside it — both actions
(`opacityChanged(_:)` line 472, `noticeDurationChanged(_:)` line 482)
update their readout live and persist only on mouse-up. That persist-on-
mouse-up rule is load-bearing; don't lose it in the refactor.

**Nothing about the closure-based delegate wiring changes.** All the
callbacks (`onSelectSize`, `onEditConfiguration`, `togglePlugin`, …) keep
their current signatures; only the assembly order moves.

### 4.2 `docs/chestnut.js` — `renderMenu()`, lines 878–1061

The website menu is a hand-built re-creation and will drift silently if it
isn't changed in lockstep. `make check` does **not** cover this; only the
sprite data is drift-checked.

- Mirror the new order and grouping exactly.
- `menuItem()` (line 844) takes `badge` as a boolean that renders `↗`.
  Extend it to accept a string so the version badge works:
  `badge: true` keeps the arrow, `badge: "0.4.0 ↗"` renders the string.
  `.menu-badge` CSS (style.css:524) already handles arbitrary content.
- Build a `sliderRow(label, min, max, value, suffix)` helper in JS to match
  the Swift one, replacing the two hand-rolled `.menu-slider` blocks.
- Move the demo's opacity and notice sliders into the Settings submenu.
- Update the section comment at lines 819–821, which currently claims
  "Size/Theme/Opacity really restyle the canvas pet" — still true, but the
  path through the menu changes.

CSS in `docs/style.css`: `.menu-slider` (564) and `.menu-readout` (added in
0.4.0) need a label span; add `.menu-slider-label` with a fixed width to
match the app. Submenu positioning (`.submenu`, 553; `.submenu.flip`, 562)
is unchanged — still only two levels.

### 4.3 Documentation

| File | Change |
| --- | --- |
| `docs/guide.html` | Menu reference table, lines 541–564, becomes nested (indent submenu rows, as the Plugins rows already are). Add Settings rows. |
| `CLAUDE.md` | Mentions "right-click menu → Plugins submenu" and carries the note that site demos drift when panels or menus change — reword for the new structure. |
| `README.md` | Check the settings section for menu-path references. |
| `CHANGELOG.md` | New entry under Changed. Frame as reorganization: no capability added or removed, everything still reachable, Size and Theme unmoved. |

---

## 5. Risks

**The site demo drifts silently.** The highest-probability failure in this
plan. Nothing automated compares `renderMenu()` to `showMenu`. Mitigation:
do the two edits in the same sitting, then open both side by side and walk
the rows in order.

**Custom-view menu rows aren't keyboard navigable.** Pre-existing — an
`NSMenuItem` with a `view` doesn't participate in arrow-key traversal, so
the opacity slider is already mouse-only today. Inlining doesn't worsen it
and arguably helps (one less hover), but it does mean the Settings submenu
opens onto two rows that can't be reached by keyboard. Worth knowing; not a
blocker, and out of scope to fix here.

**Muscle memory.** Anyone who has used 0.4.0 learns positions for Copy on
Drop and Show in Full Screen that move one level down. With the current
install base this is close to hypothetical, but it's the reason to do this
sooner rather than after the user count grows.

**Menu width.** Both slider rows set explicit frame widths, and `NSMenu`
sizes to the widest item. Declaring different widths for the two rows makes
the submenu jump. Give them the same constant.

---

## 6. Verification

`make check` will pass regardless — it has no coverage of menu assembly, and
adding some isn't worth it (an `NSMenu` built in a headless check proves
nothing about how it reads). This is a look-at-it change.

- [ ] `make check` still passes (regression guard on everything else)
- [ ] `make run`, right-click the pet, walk every row and submenu
- [ ] Opacity slider: drag, confirm live readout, confirm the pet's alpha
      tracks, confirm the value persists to `state.json` only on mouse-up
- [ ] Notice slider: same, then trigger a bubble and confirm the new timing
- [ ] Both rows: check `1s`/`30s` and `10%`/`100%` don't shift the slider
- [ ] Copy on Drop, Show in Full Screen, Launch at Login: checkmarks correct
      on open, toggles persist
- [ ] Reset Position and Edit Configuration… still work from their new home
- [ ] Version badge shows the real version and still opens the browser
- [ ] `open docs/index.html`, right-click the canvas pet, compare row by row
- [ ] Demo sliders still drive the canvas opacity and bubble duration
- [ ] Guide's menu table matches what's on screen

---

## 7. Rejected alternatives

**A real Settings window.** Would empty the menu almost entirely and is the
right answer if settings keep multiplying. Rejected for now: it's a large
build, it needs key focus (every existing panel deliberately refuses it, see
`PetPanel`), and a preferences window sits badly with an app whose whole
premise is a pixel creature you right-click. Revisit if the Settings
submenu passes roughly a dozen rows.

**About ▸ submenu** holding version, Check for Updates and Support. Saves
one more row but buries the tip jar, and a two-item submenu is thin enough
to feel like filing for its own sake.

**Grouping into Appearance ▸ and Behavior ▸.** The obvious split, and it
reads well on paper, but it puts Size ▸ inside Appearance ▸ — three levels
to change the pet's size, for the setting most likely to be explored first.

**Leaving Size and Theme inside Settings.** Same objection. Two extra
top-level rows is the right price for keeping the fun ones one hover away.

---

## 8. As built

The structure in §2 shipped unchanged. Five things differ from §3 and §4.

**Inlined sliders needed vertical air to work at all.** §2 dismissed the
`Opacity ▸` submenu as buying nothing, which ignored what it did buy: a slider
alone in a submenu has room around it. Two of them stacked at the planned 24pt
row height put their ~20pt knobs 4pt apart and read as one mashed block — the
original reason the submenus existed. Fixed with 32pt rows and 6pt of padding
top and bottom. Worth knowing that the plan's cleanest-looking simplification
was the one that nearly failed on screen.

**`Notice` was too terse to be a label.** It named an internal concept, not
anything visible. The row is **Notice Bubble**, and both rows carry a tooltip
(`sliderRow(hint:)`) as a second layer. That pushed the label column to 96pt and
the row to 290pt, against the ~56pt / ~230pt in §4.1.

**The readout closure isn't `@escaping`.** It's only called to format the
initial value; the live updates go through the static formatters directly.

**The website's checkmark column is now per-menu.** AppKit reserves the state
column only in menus that contain a checkable item — the top level indents
~10pt, Settings ▸ ~19pt. `renderMenu` mirrors that via a `has-checks` class
applied by `applyCheckColumn()`, rather than reserving the column on every row.
The three widths that have to agree (`--menu-row-pad`, `--menu-check-w`,
`--menu-gap`) now derive `--menu-label-x` for the slider rows, so the alignment
can't drift silently. Web rows also tightened (line-height 1.5 → 1.35) toward
the app's density, and `.menu-badge` gained horizontal padding it needed once
it had to hold `0.3.0 ↗` instead of a bare arrow.

**Unverified from §6.** The menu was walked on screen and the notice slider's
persist-on-mouse-up confirmed against `state.json`. Not exercised: undo rows in
their enabled state, Reset Position, Edit Configuration…, and the bubble
actually retiming after a change.
