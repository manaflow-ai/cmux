# Accessibility foundation for cmux-next React pages

Status: decision proposal, 2026-10-04. Request (Lawrence): "ensure we're using react aria or baseui
for all the things that need accessibility help, make sure to first principles pick the best
option". Evidence: `experiments/a11y-spike/` (build, keyboard scripts, axe scans, raw results).

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
  and it is one cause behind all 17 nodes. We file it upstream (mui/base-ui) with the spike as the
  repro, and the axe gate in our tests excludes only `[data-base-ui-focus-guard]` nodes, by that
  exact selector, until upstream fixes it. Any other WebKit axe node fails the gate. This is a
  waiver, flagged for Lawrence below.
- Tooltips not exposed to AT: rule 4 requires every icon-only control to have an accessible name, so
  the tooltip is never the only name.

## Migration order

Each step replaces one widget with its Base UI primitive, deletes the custom key and role code,
adds a keyboard test (Chromium and WebKit) plus an axe scan, and lands as its own PR.

| # | Widget | Base UI primitive | Owner |
| --- | --- | --- | --- |
| 1 | shared: add `@base-ui/react`, `DirectionProvider` at each page root from the resolved language, the axe gate with the single waiver | DirectionProvider | React UIs lead |
| 2 | PageMenu (shared by all pages) | Menu, ContextMenu | React UIs lead |
| 3 | Source menu + Committed submenu, options menu | Menu, SubmenuRoot, CheckboxItem, RadioItem | diff viewer owner |
| 4 | Diff pill toolbar + tooltips | Toolbar, Tooltip | diff viewer owner |
| 5 | PathPicker and its sheet | Dialog + Autocomplete (`inline open`) | diff viewer owner |
| 6 | Jump-to-file palette | Dialog + Autocomplete, virtualized | diff viewer owner |
| 7 | BranchBasePicker | Combobox with groups | diff viewer owner |
| 8 | Empty-state recents | Autocomplete inline or Combobox list | diff viewer owner |
| 9 | Settings DomainList, History tabs and list, Apps tabs, Cloud list and CreateSheet | Combobox, Tabs, Dialog | React UIs lead |
| 10 | Keybindings grid | Autocomplete grid rows, or a table with Toolbar rows (owner proposes) | React UIs lead |
| 11 | Icon picker | Autocomplete `grid` + `Row`, virtualized | React UIs lead |
| 12 | Markdown hover card, link popover, toolbar | PreviewCard, Autocomplete, Toolbar | markdown page owner |
| 13 | Composer pickers, model picker, FileSearch, ProjectChooser, NewTab omnibox, menus, SearchChats | Select, Menu, Autocomplete, Dialog | ACP UI lead (their plan, this file's rules) |

## Rules

1. Every interactive widget uses the Base UI primitive for its pattern. No hand-written `role`,
   `aria-activedescendant`, roving `tabIndex`, focus trap or arrow-key handling for a pattern that
   Base UI covers.
2. App shortcuts stay in the native dispatcher (`cmux.page.command`, `pageStreams.ts`); a page never
   binds Cmd/Ctrl chords. Widget keys (arrows, Home/End, Escape, typeahead) belong to Base UI. Domain
   keys that are not a widget pattern (the picker's drill Right/Left/Backspace) are allowed in the
   widget's `onKeyDown` and must read direction from the `DirectionProvider` value, never assume LTR.
3. Overlays render through the Base UI `Portal` part into the page root container, so page styles,
   theme variables and focus scope apply.
4. Every icon-only control has an accessible name in xcstrings; tooltips repeat it for sight only.
5. Async and filtered lists announce changes (folder, result count, loading, failure) in one polite
   live region per page; no library does this for us.
6. Styling uses our `--cmux-*` variables and Tailwind on Base UI `data-*` state attributes; no library
   theme. Motion runs only under `prefers-reduced-motion: no-preference`.
7. Every migrated widget has a keyboard test in Chromium and WebKit, LTR and RTL, and an axe scan with
   zero violations except the single focus-guard waiver.
8. A pattern Base UI does not cover (Tree, drag and drop) needs an amendment to this file before code.

## Decisions for Lawrence

- The axe waiver for Base UI's WebKit focus guards (17 nodes per open popup in the spike). The
  alternative is RAC, which had zero WebKit axe nodes but failed the async picker steps.
- Whether the markdown page owner is the diff viewer owner or another lead.
