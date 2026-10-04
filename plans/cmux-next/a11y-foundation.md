# Accessibility foundation for cmux-next React pages

Status: DECIDED (R128, coordinator, 2026-10-04): Base UI 1.8.0. Wrapper `webviews/src/ui/` landed
with the first migrated pages (markdown page, viewer-empty picker and lists). Request (Lawrence):
"ensure we're using react aria or baseui for all the things that need accessibility help, make sure
to first principles pick the best option". Spike evidence (build, keyboard scripts, axe scans, raw
results): branch `feat-cmux-next-a11y-choice` at `1908383ec88`, folder `experiments/a11y-spike/`
(kept off feat-cmux-next).

## Decision

Use **Base UI** (`@base-ui/react`, 1.8.0, MIT, MUI team) for every interactive widget in
`webviews/`. Use `@tanstack/react-virtual` for virtualized lists and grids, through Base UI's
documented `virtualized` contract. Do not add React Aria, Radix or Ariakit beside it.

React Aria Components (RAC) is the runner-up. It covers more patterns. On the widgets we have, Base
UI measured better, and the patterns only RAC has (Tree, Virtualizer, drag and drop) have no owner
in our pages today.

## What our pages need (inventory, 2026-10-04)

There is no RTL handling anywhere in `webviews/src`, but the page tables ship `ar`. Every Left/Right
binding is hardcoded (`rovingIndex` in `toolbar-model.ts:324`, `pickerModel.ts:128`, `useMenuTree.ts`,
`icon-picker/keyboard.ts:26`). No focus trap exists: `SearchChats.tsx:101` and `cloud/CreateSheet.tsx:46`
say `aria-modal` but trap nothing. Typeahead exists nowhere. The only virtualized widget,
`icon-picker/VirtualGrid.tsx`, points `aria-activedescendant` at cells that leave the DOM.

| Widget (file) | Pattern | Main defects today | Owner |
| --- | --- | --- | --- |
| Source menu with Committed submenu (`DiffToolbar.tsx:115`) | menu button with submenu | no typeahead; Escape in submenu closes everything; submenu arrows not RTL; outside click skips focus restore | diff viewer owner (cmuxterm-hq-48) |
| Jump-to-file palette (`DiffToolbar.tsx:320`) | dialog + combobox + listbox | input lacks `role=combobox`/`aria-expanded`; Home/End ignored; silent 200-row cap | diff viewer owner |
| Options menu, diff pill toolbar, CSS tooltips (`DiffToolbar.tsx:480`) | toolbar (roving) + menu + tooltip | arrows not RTL; Escape restores by hardcoded id; tooltips invisible to AT | diff viewer owner |
| BranchBasePicker (`BranchBasePicker.tsx:330`) | combobox popup with groups | `aria-haspopup=listbox` opens a dialog; no combobox role; loading not announced | diff viewer owner |
| PathPicker drill (`viewer-empty/PathPicker.tsx`, `pickerModel.ts`) | combobox + listbox + breadcrumb, async | no combobox role; folder change not announced; arrows not RTL; no trap | diff viewer owner |
| Empty-state recents (`viewer-empty/EmptyState.tsx:104`) | listbox | no typeahead | diff viewer owner |
| Markdown link hover card, link popover, toolbar (`pages/markdown/linkEditing.ts`, `MarkdownPage.tsx:51`) | tooltip/preview card, combobox, toolbar | hover card mouse-only; suggestions have no ids so AT hears nothing; toolbar has no roving focus | markdown page owner (coordinator assigns) |
| Composer pickers, model picker, FileSearch, ProjectChooser, NewTab omnibox, menus, SearchChats (`agent-session/acpmux/*`) | select-only combobox, cascading menu, combobox in dialog, modal dialog | `aria-checked` on options; combobox pops a menu; omnibox lacks combobox role; no traps; arrows not RTL | ACP UI lead (inventory only here) |
| PageMenu, Settings DomainList, History tabs/listbox, Apps tabs, Keybindings grid, Cloud list/sheet, icon picker grid (`pages/*`, `icon-picker/*`) | menu, tabs, listbox, grid, dialog, virtualized grid | menu focus stays on container; tabs without arrows or panels; grid without cell navigation; virtualized activedescendant dangles | React UIs lead |

## Candidates compared on what we need

| | Base UI 1.8.0 | React Aria Components 1.21.1 | Ariakit 0.4.40 | Radix 1.6.7 |
| --- | --- | --- | --- | --- |
| Menu + submenu, typeahead | yes | yes | yes, but Escape closes all levels | yes, but Escape closes all levels |
| Combobox with async items, inline list | Autocomplete `inline open`, `autoHighlight="always"`, `onItemHighlighted` | Autocomplete: textbox (not combobox), first row highlighted only after typing; ComboBox is popup-first | yes, but no highlight after async load | none |
| Grid inside combobox (icon picker) | Autocomplete `grid` + `Row` | GridList | composite rows | none |
| Virtualization | external (`virtualized` + TanStack Virtual, documented) | built-in `Virtualizer` | external | none |
| Tree | none | Tree, NavigationTree | none | none |
| Toolbar, roving focus | yes (no Home/End, which APG marks optional) | yes (no Home/End) | yes, with Home/End | yes, with Home/End |
| Drag and drop | none | first-class | none | none |
| RTL | `DirectionProvider` | from locale (`I18nProvider`) | per-component `rtl` | `Direction.Provider` |
| Built-in strings | almost none; all labels are ours | 34 locales; 4 of our 21 (bs, km, th, vi) fall back to English | none | none |
| Styling | unstyled, `className` fn, `data-*` state, `render` prop | unstyled, `className` fn, `data-*` | unstyled, `render` | unstyled, `asChild`, `data-state` |
| Portals and traps | explicit `Portal` part with `container`; `modal` prop | overlays portal to body by default; `UNSAFE_PortalProvider` redirects | `portal` prop | optional `Portal` part; `modal={false}` |
| Stability | 1.0 since 2025-12; 9 releases in 2026 | 1.x; monthly | still 0.x | last release 2026-07-24, no merges since 2026-08-09 |

## Spike results

Same three widgets per library: the Source menu with a Committed submenu, the path picker (async
drill-down combobox over a 40 ms fake listing), and a four-button toolbar with tooltips. Production
build, React 19.2.3, React Compiler on. Keyboard-only Playwright scripts in headless Chromium and
WebKit (Playwright 1.62.1), LTR and RTL; axe-core 4.13.0 at five states. Run:
`cd experiments/a11y-spike && bun install && node build.mjs && node run.mjs`.

Bundle (gzip, library cost over a React-only baseline of 59.6 KB):

| Base UI | RAC (all locales) | RAC (our 21 locales) | Ariakit | Radix (no combobox) |
| --- | --- | --- | --- | --- |
| +63.7 KB | +61.8 KB | +60.0 KB | +49.7 KB | +32.3 KB |

React Compiler: every spike component compiled with zero diagnostics for every library, and the
keyboard scripts ran against the compiled output. The compiler does not compile library code.

Keyboard (APG-required steps passed) and axe (serious + critical nodes):

| Library | Chromium LTR | Chromium RTL | WebKit LTR | WebKit RTL | axe Chromium | axe WebKit |
| --- | --- | --- | --- | --- | --- | --- |
| Base UI | 22/22 | 14/14 | 22/22 | 14/14 | 0 | 17 |
| RAC (Autocomplete picker) | 19/22 | 14/14 | 18/22 | 14/14 | 0 | 0 |
| RAC (ComboBox picker, one attempt) | 16/23 | 14/14 | 16/23 | 14/14 | 6 | 6 |
| Ariakit | 19/22 | 13/14 | 18/22 | 13/14 | 0 | 0 |
| Radix (menu + toolbar only) | 13/14 | 13/14 | 13/14 | 13/14 | 2 | 2 |

What failed, by cause:

- **Base UI WebKit axe (17 nodes, one cause).** On macOS WebKit Base UI gives its focus-guard spans
  `role="button"` with no name, so VoiceOver's virtual cursor fires focus on them
  (`utils/FocusGuard.js`). axe reports `aria-command-name` and, inside the open menu,
  `aria-required-children`. `modal={false}` does not remove them. WKWebView is our only engine, so
  every cmux page has this while a popup is open.
- **Base UI semantics.** Tooltip popups have no `role=tooltip` and triggers no `aria-describedby`;
  Base UI treats tooltips as sighted-only hints and expects the trigger's `aria-label` to carry the
  name. No library announced the picker's folder change; that live region is ours to write.
- **RAC picker.** The Autocomplete input is a textbox with `aria-activedescendant`, not a combobox.
  No row is highlighted after an async listing or a drill until the user types or presses Down. RAC
  has no highlighted-key callback, so the drill keys read `aria-activedescendant` from the DOM. In
  WebKit, RAC re-dispatches Backspace to the collection and the second, unprevented event made the
  Playwright browser navigate back (Safari and WKWebView have no Backspace-back by default, so this
  is probably harness-only). Driving RAC's ComboBox through `ComboBoxStateContext` to keep an inline
  list highlighted failed in one attempt and added `aria-hidden-focus`.
- **Ariakit and Radix.** Escape in a submenu closes the whole menu. Ariakit's `autoSelect` does not
  highlight a row when items arrive later. Radix has no combobox at all and `aria-hidden-focus` on
  the page root while a menu is open.

## Why Base UI

1. It is the only library that passed every required keyboard step on all three widgets in both
   engines and both directions, and its picker code needed no DOM reads: `onItemHighlighted`,
   `inline open` and `autoHighlight="always"` express our drill picker directly.
2. Our widget list is menus, comboboxes (several async, one grid), toolbars, tooltips, dialogs,
   tabs and listboxes. Base UI has a primitive for each, including Autocomplete grid rows for the icon
   picker and a documented TanStack virtualization path.
3. All user-visible strings stay ours in xcstrings for all 21 locales. RAC's built-in strings would
   speak English in bs, km, th and vi.
4. Portals are an explicit part with a `container`, so a page inside cmux decides where overlays go.
5. Bundle cost equals RAC's within 4 KB gzip.

## Strongest objection, and how it is handled

"React Aria is the more complete and more rigorously accessible library: it alone has Tree,
Virtualizer and drag and drop, it was the cleanest on WebKit axe, and Base UI ships an axe-failing
focus guard in exactly our engine."

- Tree and drag and drop: no page we own needs them. The file tree is `@pierre/trees` (third party);
  tab and pane drag is native. If a React-owned tree appears, its owner amends this file before
  writing code; we do not add a second library silently.
- Virtualization: Base UI's `virtualized` contract plus TanStack Virtual keeps the highlighted item
  rendered and sets `aria-setsize`/`aria-posinset`; the icon picker migration must prove that with a
  test that scrolls the highlight out of view.
- The focus guard: it is a deliberate VoiceOver workaround, it appears only while a popup is open,
  and it is one cause behind all 17 nodes. Lawrence files it upstream (issue text below); the axe
  gate in our tests (test/ui-a11y.test.ts) excludes only `[data-base-ui-focus-guard]` nodes, by that
  exact selector, plus `aria-required-children` on a popup whose offending children are those spans,
  until upstream fixes it. Any other axe node fails the gate. The waiver stands only after the
  VoiceOver pass below confirms the guards neither trap focus nor clutter speech.
- Tooltips not exposed to AT: rule 4 requires every icon-only control to have an accessible name, so
  the tooltip is never the only name.

## The wrapper: `webviews/src/ui/`

One folder inside `webviews/`, not a workspace package. `webviews/` is its only consumer; a package
would add a build or a second resolution of React and Base UI (two React copies break hooks and
Base UI's `flushSync`), and the rules scanner keys on the folder path. Import each widget from its
module (`../ui/Toolbar`). There is no barrel: the viewer pages' shared `pickerModel` chunk captures
every module its members import, and a barrel would pull all of Base UI into the eager diff, editor
and markdown chunks.

| Export | Over | Notes |
| --- | --- | --- |
| `UiProvider`, `languageDirection` | Base UI `DirectionProvider` | every page root: the portal container (the page's root element) and the direction from the page's resolved language (`ar` is RTL) |
| `Menu`, `MenuButton`, `MenuPopup`, `MenuItem`, `MenuCheckboxItem`, `MenuRadioGroup`/`MenuRadioItem`, `MenuGroup`, `MenuSeparator`, `Submenu` | Base UI Menu | non-modal; submenus at the inline end |
| `Popover` (element or point anchor), `virtualAnchor` | Base UI Popover | non-modal; `initialFocus`, `finalFocus` |
| `Tooltip`, `TooltipProvider`, `AnchoredCard` | Base UI Tooltip | `AnchoredCard` is a hover card for DOM React does not own (editor links), `role="tooltip"` |
| `Toolbar`, `ToolbarButton` (with a hint), `ToolbarToggleGroup`, `ToolbarGroup`, `ToolbarSeparator` | Base UI Toolbar, ToggleGroup, Toggle | disabled buttons stay focusable; the hint is a lazily loaded `AnchoredCard` on hover and keyboard focus (500 ms, then at once within 400 ms; Escape hides), so the open path carries no Floating UI and the button never remounts |
| `Dialog` | Base UI Dialog | modal: trap, inert page, Escape, outside press, focus return |
| `Disclosure` | Base UI Collapsible | |
| `Combobox` | Base UI Autocomplete | suggestions under a field; `inline` inside a popover; Return submits, Tab completes, Escape cancels |
| `VirtualList` | TanStack Virtual | the active row always rendered (even before the first measure), scrolled into view; callers set `aria-posinset`/`aria-setsize` |
| `DrillList` | ours | drill-down combobox (see below) |
| `Listbox` | ours | focusable listbox with typeahead (see below) |
| `ChoiceGroup` | native radios | Return submits and Escape steps back, so pages carry no key handler |
| `Breadcrumbs` | native buttons in a `nav` | |
| `drillKeyAction`, `DRILL_WIDGET_CHORDS` | ours | the drill-down key table, also the app palette picker's reference |

Three widgets are ours, inside the wrapper, because Base UI 1.8 has no primitive for them (flagged
for Lawrence below): `DrillList` needs a caller-controlled highlight (going up highlights the folder
it came from; Base UI Autocomplete highlights only from its own keyboard state and exposes no setter);
`Listbox` and `ChoiceGroup` because Base UI has no standalone listbox and the native radios are
already right. Each is the one implementation, with jsdom and real-engine tests.

Styling (`ui/ui.css`, R139 desktop feel): system font, chrome `user-select: none` (fields selectable),
focus rings only on `:focus-visible`, colors only from `--cmux-*` with system-color fallbacks,
transitions only under `prefers-reduced-motion: no-preference`.

### Enforcement

- `test/ui-rules.test.ts` (scanner `test/ui-rules.ts`) fails on page code outside `src/ui/` that
  sets a widget `role` (listbox, option, menu*, combobox, grid*, tab*, toolbar, tooltip, dialog,
  tree*, slider, switch, radio*, checkbox, button, link, ...), a `tabIndex`, a key handler
  (`onKeyDown`/`onKeyUp`/`onKeyPress` or `addEventListener("keydown"...)`), or a portal
  (`createPortal`, `document.body.append`). Landmark and status roles (`alert`, `img`, `region`) are
  fine. Files not yet migrated are in `test/ui-rules.pending.json` with their count: a count may only
  go down, a clean file must leave the list, and `viewer-empty/` and `pages/markdown/` may never
  appear. A line marked `// ui-allow: <reason>` is exempt; there are four, all reviewed: the editor's
  follow cursor (it tracks the Meta key, `linkEditing.ts`, three lines) and the dev picker's host
  (`viewer-empty/dev.tsx`, the container its dialog portals into).
- App shortcuts: `test/ui-wrapper.test.tsx` presses Cmd-S, Cmd-K, Cmd-W, Ctrl-Tab and Cmd-Return on
  every wrapper widget with keys and checks each reaches the document unhandled. The only chords a
  wrapper widget takes are `DRILL_WIDGET_CHORDS` (Cmd-Up, Ctrl-N, Ctrl-P, while a drill field has
  focus). Cmd-K for the link popover stays the app's `link` page command.
- Portals: `test/ui-a11y.test.ts` checks that the menu, the picker dialog and the link popover render
  inside the page container in both engines.
- Tests load Base UI's environment check first (`webviews/bunfig.toml` preload, `test/preload.ts`):
  Base UI picks layout effects or a no-op when its module first loads, by whether `document` exists,
  and bun shares one module cache across test files.

## First pages migrated (this landing)

Markdown page (`pages/markdown/`): the toolbar is a ui `Toolbar` (Back and Forward with hints,
mirrored glyphs in RTL; Rich and Source a toggle group; file and status inside). The link popover is
a ui `Popover` with a ui `Combobox` and the hover card a ui `AnchoredCard`; both now render in the
page's own React tree from an overlay store (`overlays.ts`, `LinkOverlayHost`, loaded after the
page) instead of nodes appended to `document.body`. New: the hover card also shows for the link around the caret, not only
under the pointer. The editable region now has an accessible name and `role="textbox"`
(`aria-multiline`): axe found it unnamed. The save status uses the muted color, not the faint one:
axe found it under 4.5:1.

Picker (`viewer-empty/`): `PathPicker` is a ui `DrillList` in a ui `Dialog` (`PathPickerDialog`),
`RecentList` a ui `Listbox`, the diff source choice a ui `ChoiceGroup`, the breadcrumb ui
`Breadcrumbs`. PICKER-PATHS, as built (no written spec was found in plans/; this is the coordinator's
list, interpreted): no `~` jump key (typing `~` alone is text); a Locations section above the level
while the query is empty (Home, the computer's root, up to three recent folders, the shown folder left
out); path mode when the query starts with `/` or `~/` (the picker lists the typed folder and the last
part filters it; entering and going up keep the field a path); Cmd-Up for the parent (Left at the
start and Backspace on an empty query still go up); a hint under the field ("Type / or ~/ to enter a
path. ⌘↑ opens the enclosing folder."). Five new strings in 21 locales (`picker.locations`,
`picker.home`, `picker.computer`, `picker.hintPath`, `picker.status`; only en and ja reviewed). The
field placeholder still says "Filter, or type ~ or /" (21 locales; a copy follow-up).
The diff page's empty state now loads on demand (`viewer-empty/emptySurface.ts`), so an open
repository never evaluates Base UI.

### Results (2026-10-04, on feat-cmux-next at 7e7e09a5533)

| Gate | Result |
| --- | --- |
| `test/ui-a11y.test.ts` (keyboard only, Chromium and WebKit, LTR and RTL; menu+submenu, toolbar, recents, picker incl. a 2,000-entry level, markdown toolbar, link popover, caret hover card) | 20/20 pass, twice in a row |
| axe, WCAG 2.x A/AA, at 9-10 states per engine and direction | 0 violations; waived focus-guard nodes per run: 12 on Chromium (focusable `aria-hidden` spans), 27 on WebKit (unnamed `role=button` spans); `region` (best practice) logged, not gating |
| full `bun test` | 1987 pass, 0 fail (212 files) |
| `vp check` | pass: no warnings, lint errors or type errors (733 files) |
| bundle checks | `build-webviews-app.sh --check`, agent pane, agent activity and pages `--check` all current |
| React Compiler guard | enabled, 73 cache sites across 442 files |
| `check-webviews-diff-budget.mjs` | all six budgets pass |

Eager JS on open (static import closure), against the bundle committed on feat-cmux-next:

| Page | Minified | Gzip |
| --- | --- | --- |
| markdown page | 1,105,256 to 1,146,759 (+41.5 KB) | +14.7 KB |
| diff surface | 1,418,182 to 1,411,665 (-6.5 KB; its empty state is now lazy) | -1.6 KB |
| editor page | 414,363 to 421,116 (+6.8 KB, the recent list) | +2.2 KB |
| agent session | +23 bytes | 0 |

Base UI itself (popover, autocomplete, dialog, tooltip, Floating UI) is in lazy chunks; the
committed `webviews-app` bundle grows by about 190 KB on disk.

### VoiceOver pass (required for the waiver): NOT RUN, needs Lawrence

cmux-lawrence-2 is reachable over SSH, but VoiceOver's speech cannot be read without AppleScript
(banned), and `cua-driver permissions status` there reports Accessibility and Screen Recording
`unknown` (no verified grant). Steps for Lawrence, on cmux-lawrence-2:

1. In a checkout of feat-cmux-next: `cd webviews && bun install && bunx vp dev --port 4870`.
2. Save the host below as `/tmp/wkhost.swift` (it type-checks there with `swiftc -typecheck`) and run
   `swift /tmp/wkhost.swift "http://127.0.0.1:4870/test/browser/ui-a11y.html?case=widgets"`.
3. Turn VoiceOver on (Cmd-F5) and use only the keyboard:
   - Tab to Source: expect "Source, menu button". Return: "Working tree, menu item, 1 of 3" (or the
     menu name first). Type `c`: "Committed, submenu". Right: "HEAD~1". Escape: back on "Committed",
     one level closed. Escape again: back on "Source".
   - Tab to the toolbar: "Split view, button, toolbar"; Right: "Unified view"; the tooltip text is not
     read twice. Tab once leaves the toolbar.
   - Tab to the recent list: "Recent repositories, list box", Down reads each row.
4. Rerun step 2 with `?case=picker`: on open, focus is in "Filter, combo box", the hint is read as its
   description, Down reads rows, entering a folder announces "~/fun, 3 items" (the status line).
5. Rerun with `?case=markdown`: Tab into the toolbar (Back, Forward, then Rich and Source read as
   toggle buttons with their pressed state); Tab into the document: "Markdown, edit text" (the
   harness labels it "document").
6. For each popup in steps 3-4, move the VoiceOver cursor (VO-Right) past the last item: it must not
   stop on an unnamed "button" (the guard spans) and must not leave the popup's content in a loop.
   Record pass or fail per widget in this section.

```swift
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
  contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "ui a11y (WKWebView)"
let web = WKWebView(frame: window.contentView!.bounds)
web.autoresizingMask = [.width, .height]
window.contentView!.addSubview(web)
window.center()
window.makeKeyAndOrderFront(nil)
web.load(URLRequest(url: URL(string: CommandLine.arguments.dropFirst().first ?? "http://127.0.0.1:4870/test/browser/ui-a11y.html")!))
app.activate(ignoringOtherApps: true)
app.run()
```

### Issue text for mui/base-ui (Lawrence files it; not filed by an agent)

> **Focus guards are unnamed buttons on macOS WebKit (axe `aria-command-name`, `aria-required-children`)**
>
> `@base-ui/react` 1.8.0, macOS 27, WebKit (Safari and WKWebView). While a Menu, Popover or Dialog is
> open, `FocusGuard` (`utils/FocusGuard`) renders `<span tabindex="0" role="button">` with no
> accessible name when it detects VoiceOver on WebKit, so VoiceOver's cursor fires focus on it. axe-core
> 4.13 reports each guard as `aria-command-name` (serious), and an open menu as
> `aria-required-children` (critical) because the guards sit inside `role="menu"`. On Chromium the
> same guards are `aria-hidden="true"` with `tabindex="0"`, which axe reports as `aria-hidden-focus`.
> Repro: open a `Menu` with a `SubmenuRoot` in Safari and run axe; we count 17 nodes with the submenu
> open. Could the guards carry an accessible name (or `aria-roledescription`) that VoiceOver skips, or
> sit outside `role="menu"`, so the workaround stays without the violations? We can test a patch in
> WKWebView.

## Migration order (what remains)

Each step replaces one widget with its ui primitive, deletes the custom key and role code, removes
its line from `test/ui-rules.pending.json`, adds a keyboard test (Chromium and WebKit, LTR and RTL)
plus an axe scan, and lands as its own change.

| # | Widget | ui primitive | Owner | Status |
| --- | --- | --- | --- | --- |
| 1 | shared: `@base-ui/react`, `UiProvider` at each page root, the axe gate with the single waiver | UiProvider | React UIs lead | done for markdown and viewer-empty; each page adds it when it migrates |
| 2 | PageMenu (shared by all pages) | Menu | React UIs lead | |
| 3 | Source menu + Committed submenu, options menu | Menu, Submenu, MenuCheckboxItem, MenuRadioItem | diff viewer owner (cmuxterm-hq-48) | |
| 4 | Diff pill toolbar + tooltips | Toolbar, Tooltip | diff viewer owner | |
| 5 | PathPicker and its sheet | Dialog + DrillList | diff viewer owner | done |
| 6 | Jump-to-file palette | Dialog + DrillList (or Combobox), VirtualList | diff viewer owner | |
| 7 | BranchBasePicker | DrillList with sections | diff viewer owner | |
| 8 | Empty-state recents and source choice | Listbox, ChoiceGroup | diff viewer owner | done |
| 9 | Settings DomainList, History tabs and list, Apps tabs, Cloud list and CreateSheet | Combobox, Tabs (to add), Dialog | React UIs lead | |
| 10 | Keybindings grid | owner proposes (Base UI has no grid; amend this file first) | React UIs lead | |
| 11 | Icon picker | Base UI Autocomplete `grid` + VirtualList (to add to ui) | React UIs lead | |
| 12 | Markdown hover card, link popover, toolbar | AnchoredCard, Popover + Combobox, Toolbar | markdown page owner | done |
| 13 | Composer pickers, model picker, FileSearch, ProjectChooser, NewTab omnibox, menus, SearchChats | Menu, Combobox, DrillList, Dialog | ACP UI lead (their plan, this file's rules) | |

## Decisions for Lawrence

- The axe waiver for Base UI's focus guards (27 WebKit nodes and 12 Chromium nodes per test run).
  It stands only after the VoiceOver pass above; RAC is the fallback if VoiceOver fails.
- `DrillList`, `Listbox` and `ChoiceGroup` are wrapper-owned code (Base UI has no primitive). The
  alternative was Base UI Autocomplete for the picker, which loses "going up highlights the folder you
  came from".
- Cmd-Up is a widget chord inside the picker field (Finder's convention). If the app's dispatcher
  binds Cmd-Up, WKWebView never delivers it to the page; Left and Backspace still go up. Not checked
  in the app.
- The picker still caps a level at 300 rows ("N more, type to filter"), now virtualized. Lifting the
  cap is safe with `VirtualList` but changes the app palette picker's reference rule.
- Toolbar hints are wrapper code (hover and focus timing) over a lazily loaded Base UI card, not
  Base UI's own Tooltip trigger: the eager Tooltip put the markdown page 43 KB over its 1.2 MB
  budget, and a lazy Base UI trigger remounts the button and drops keyboard focus.
- Whether the markdown page owner is the diff viewer owner or another lead.
