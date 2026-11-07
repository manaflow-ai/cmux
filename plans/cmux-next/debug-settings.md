# cmux-next Debug Settings and tunables

User request (2026-10-01): more variations of the tab drop overlay, and a
dev-nightly only Debug Settings window (Cmd-Shift-P > Open Debug Settings),
a real settings window closable with Cmd-W, that searches every value that
can be fine tuned.

## Ownership

Tunable overrides are preferences of this Mac (OWNERSHIP-PRINCIPLES.md,
"Preferences"), owned by the config layer, client-side only. Nothing reaches
the daemon or the workspace store. Defaults stay in code; the store holds
only overrides.

## Gate

`DevTools` (CmuxNextActions): a Debug compile, or a bundle id of
`com.cmuxterm.app.nightly[.<tag>]`. NIGHTLY compiles in Release like RC and
stable, so `#if DEBUG` cannot separate them; the bundle id can. In Release
and RC the `isDebugOnly` actions are unavailable in every surface and the
store never activates, so every tunable reads its code default and no file
is read. `isDebugOnly` now means DEV and NIGHTLY (no action used it before).

Bench builds (Release with `CMUX_BENCH_HOOKS`, the fleet's film and bench
builds) are not `DevTools` either, so launch leaves the store off there too,
but they have the `debug.tunables` socket method. Its `activate` action turns
the store on for that launch: it registers the catalog and activates the
store with no file, so overrides live in memory only, nothing is written, and
the next launch starts off again. It does nothing on a store that is already
on (DEV, NIGHTLY), and nothing changes unless a client calls it: a bench that
never calls it keeps the inert store (every read one atomic load). What a
`set` after `activate` reaches (FRAME OWNER REFACTOR S0):

- A reader at each use (`Tunable.value` read per frame, a spring read when its
  motion starts, `MotionSpring.base`): its next read.
- A reader that tracks the key after `activate` (`withObservationTracking`, a
  view): it is told of each change.
- A reader that tracked the key before `activate`: an off store returns before
  it registers the dependency, so an observation that reads only tunables
  never fires and the reader keeps what it read (one that also reads other
  state fires for that state, reads again and follows from then on).
  `SidebarTunablesWatch` keeps its launch snapshot (agent mark, presence dots,
  row badge, stack cap, title motion, quiet unnamed rows, row title,
  single-chat title) until a relaunch; `sidebar.rowCloseSpot` follows,
  because each row layout reads it. An `ObservationStream` loop that started
  before (an open agent page's `icons.family`) stays where it is.
- A reader at one moment: `browserResize.dragResize`'s `synced` choice is read
  once, when Chromium starts (`dragResizeAtLaunch`). cmux pages, New Tab and
  agent chats included, show in Chromium by default (`browser.defaultEngine`,
  `agent.chromium`), and the launch's New Tab spare page starts it about
  250 ms after the first frame (a restored page sooner), normally before a
  socket client has sent `activate`: a bench build cannot count on reaching
  `synced` this way. `debug.cef` shows whether, why and when Chromium started
  (`state`, `trigger`, `ready_after_launch_s`). `browserResize.layerHosting`
  applies at a page's next show; each tunable's help says when it applies.
  `icons.family`: native icons read it at launch; agent pages made after the
  `set` use it, but the first page that takes the spare made at launch (a New
  Tab, a new workspace's first page, an existing chat of this Mac) keeps the
  old family.
- Readers gated on `DevTools.isEnabled`, or wired only by
  `DebugSettingsService.start()`, keep their Release behavior in a bench build
  whatever the store holds: `auth.signInWindow`, `home.chiefViewGallery`,
  `sidebar.sections.localPrototype`, `home.flightRecorder` and its captures.

## Registry

- `Tunable<Value>` (constant default) and `DerivedTunable` / `ComputedTunable`
  / `MetricTunable` (defaults computed from density or other tokens).
  Kinds: number (range, step, unit), bool, choice (`TunableChoice` enums),
  theme color role (`TunableColor`, no blue or cyan), spring.
- `TunableStore`: `Mutex` state plus an `ObservationRegistrar` keyed per
  tunable, so a read is a lock and a lookup, safe off the main actor (Motion
  tokens), and only views that read a key re-render when it changes.
- File: `~/Library/Application Support/cmux/<tag or channel>/debug-tunables.json`,
  `CMUX_NEXT_DEBUG_TUNABLES_FILE` overrides it. Read off the main actor at
  launch (values apply when it lands); writes coalesce to the newest
  snapshot off the main actor. Unknown keys and values that do not fit are
  dropped; numbers and springs are clamped.
- Exports: changed values as JSON, and as Swift defaults
  (`<code name>: <literal>` with the old default in a comment).
- Catalog: `TunableCatalog.all` in the App joins `DesignTunables`,
  `LayoutTunables`, `TabTunables`, `SidebarTunables`, `DragTunables`.
  A new tunable is one declaration in its module plus its list.

## Window

`DebugSettingsWindowController` (CmuxNextSettingsWindow): the Settings
window's style, a sidebar (search, All, Changed, sections with counts and a
dot when changed), rows with label, key, help, control (slider plus exact
field), default, and Reset; Reset Section, Reset All, the two exports.
Cmd-W closes it in the window's own key equivalents (the app's Close Tab
must not reach the main window), Cmd-F focuses search, Escape clears the
search then closes, size autosaves, no-activate launches never make it key.
Entry points: palette `openDebugSettings` (CLI verb `debug open-settings`
for the Rust CLI) and `debug.tunables` on the socket.

Labels and help are English developer text, not localized: the window ships
only in DEV and NIGHTLY. The window chrome is localized.

## Drop overlay styles

`DropHighlightView` owns the motion (target and region springs, the token
from `drop.overlay.spring`, `settle` for morph) and draws one renderer:

| Style | Look |
| --- | --- |
| `glassFill` (default) | Liquid Glass filling the target, label centered (unchanged) |
| `glassOutline` | a glass band tracing the target's edge |
| `insetCard` | faint region tint, a glass card with split glyph and label |
| `splitPreview` | the incoming pane in glass and the existing pane outlined, at final sizes with a gap |
| `insertionLine` | a thick rounded caret on the new divider (or along the strip for a center drop) |
| `edgeGlow` | a gradient growing inward from the edge the new pane takes |
| `tabGhost` | a glass tab pill where the tab lands in the strip |
| `dimOthers` | spotlight: everything outside the target dimmed |
| `morph` | glass growing from the pointer, morphing between targets with `settle` |
| `hairline` | a one-pixel frame |
| `dashed` | a dashed outline |
| `corners` | viewfinder brackets |

Glass styles draw through `OverlaySurfaceView`, so `OverlayMaterial.select`
stays the single material choice (blur before macOS 26, opaque under Reduce
Transparency). Reduce Motion snaps every style. Colors are theme roles; the
line color tunable offers no blue. Hit testing, `DropTarget` and commits are
unchanged.
