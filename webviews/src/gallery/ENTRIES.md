# Adding gallery entries

One entry is one file, `<Name>.gallery.ts` (or `.tsx`), next to the page or component it shows. Its
default export is the entry. The gallery finds every such file under `webviews/src` by itself
(`src/gallery/registry.ts` in the browser, `scripts/gallery/entries.ts` in tests). There is no list
to edit. Each file loads on its own: if yours does not compile, throws or exports nothing, the
gallery shows an error card for it alone and every other entry keeps working.

## The entry

`src/gallery/format.ts` has the types. An entry has:

- `id`: dotted lower kebab case, `area.name` (`pages.diff`, `agent-pane.sources`). It is the same in
  the native gallery. Do not reuse an id that another lane owns.
- `title` and `area`: the sidebar label and group (`Agent pane`, `New Tab`, `Pages`,
  `Home and Chief`, `Settings`, `Native`).
- `covers`: what the entry shows, for the coverage test. Use `<path under webviews/src>#<Export>` for
  one component, the path alone for every export of a file, and `page:<PageDescriptor id>` for a page.
- `variants`: named states, lower kebab case. Each variant is plain data of the real structures. A
  variant is never a copy of the component.
- `experimental: true`: surfaces behind a flag or not shipped yet appear in the Experimental
  section at the bottom of the sidebar and carry an Experimental badge in their header. Set this
  on thread minimap, thread widget and code widget entries when those surfaces are registered;
  keep each entry's normal `area` so it returns there when the surface ships.
- Optional: `height` (the component-mode stage height), `widths` (pane widths for component mode),
  and a variant's `note` (one line in the stage header).

The host decides how the real code receives the data:

| helper               | host                                                            | a variant is                                                                                                                    |
| -------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `agentPaneEntry`     | the whole agent pane (`acpmux/mount.tsx`) on the pane bridge    | `{ ready?, snapshot }`: the `ready` answer fields and an `AcpmuxSnapshot`                                                       |
| `markdownPageEntry`  | the markdown page entry on an in-page cmuxPage host             | `{ path, text, readOnly?, settings?, files? }`                                                                                  |
| `diffPageEntry`      | the diff page entry on an in-page cmuxPage host                 | `{ files: [{ path, before?, after? }] }` or `{ patch }`, `layout?`                                                              |
| `settingsPageEntry`  | the settings page on its real mock provider through cmuxPage    | `{ section, focus?, options?, host?, accounts?, steps? }`                                                                       |
| `passwordsPageEntry` | the passwords page on its real mock provider through cmuxPage   | `{ data, loading?, authenticate?, failure?, steps? }`                                                                           |
| `componentEntry`     | one React component under `UiProvider` and the page base styles | `{ props }`, plus `load: () => import(...)`; optional `chipHost` supplies public-safe answers for reply chip/preview host calls |
| `nativeEntry`        | the native gallery only (CmuxNextGallery)                       | `{ fixture }`: a repo path of a Swift model's JSON                                                                              |

For another page (cloud, history and the rest), add a host in `src/gallery/frame/pages.ts`
on the same pattern: `installMockHost(ops, streams)` from the page's ops, then `import` the page's
real `main.tsx`. Then add its helper and variant type to `format.ts`.

Fixtures are public-safe sample data: no tokens, emails, keys or real user content. Put
`// l10n-allow-file: gallery fixtures` on the first line; the agent pane's string scanner skips the
file then. Builders for the pane's structures (rows, tool calls, sessions, snapshots) are in
`src/gallery/fixtures/acpmux.ts`. Times are relative to the gallery clock (`src/gallery/clock.ts`),
so `minutesAgo(5)` reads "5m" in every run.

## Example: a page (the diff viewer)

```ts
// l10n-allow-file: gallery fixtures (sample code), not shipped UI.
import { diffPageEntry } from "../../gallery/format";

export default diffPageEntry({
  id: "pages.diff",
  title: "Diff viewer",
  area: "Pages",
  covers: ["page:cmux.diff", "App.tsx", "DiffToolbar.tsx"],
  variants: {
    "small-split": {
      note: "One file changed, one added.",
      files: [
        { path: "src/net/client.ts", before: "export const a = 1;\n", after: "export const a = 2;\n" },
        { path: "src/net/retry.ts", after: "export const tries = 3;\n" },
      ],
    },
    unified: { layout: "unified", files: [{ path: "src/a.ts", before: "x\n", after: "y\n" }] },
  },
});
```

## Example: a component

```tsx
// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../gallery/format";
import type { DisclosureProps } from "./Disclosure";

export default componentEntry<DisclosureProps>({
  id: "ui.disclosure",
  title: "Disclosure",
  area: "Pages",
  covers: ["ui/Disclosure.tsx#Disclosure"],
  load: () => import("./Disclosure").then((module) => module.Disclosure),
  styles: () => import("./ui.css"),
  variants: {
    closed: { props: { title: "Advanced", children: "Hidden text" } },
    open: { props: { title: "Advanced", defaultOpen: true, children: "Shown text" } },
  },
});
```

(This shows the shape only. Check the component's real props before you copy it.)

## Window mode

Window mode is the default view. The surface renders at the real size of its pane: the window
preset (16:9 by default), the app's metrics (`MetricTunables.swift` for each density: sidebar
width, titlebar, tab strip, column gap) and `Panes` (`one`: the whole content area; `two`: the
left of two panes; `agent-right`: the right column) give the pane size. Only the surface is drawn,
inside a plain neutral frame with a caption (the preset and the pane size in points). Nothing of
the native window (sidebar, tab strip, title bar) is imitated. The shell scales the finished
surface down with one transform, so nothing reflows. A full-page surface uses `one`. You add
nothing for window mode. `component` mode shows the entry at a chosen pane width, for close work.

## Play steps and checks

A variant can drive the mounted page into an interactive state with `play` (`src/gallery/play.ts`).
The steps run after mount and before the stage is ready, so the screenshot and the shell show the
played state. The shell runs them when a variant opens and has a Replay button; the matrix runner
runs the same function before each screenshot, with trusted Playwright input.

```ts
"slash-menu": {
  snapshot: chat(rows, { commands }),
  play: async (ctx) => {
    await ctx.click({ selector: "[contenteditable='true']" });
    await ctx.type("/");
    await ctx.waitFor(() => ctx.document.querySelector("[role='listbox'], [role='menu']"));
  },
},
```

`ctx` has `click`, `hover`, `focus`, `scroll(target, position)`, `selectText(target)`,
`type(text, target?)`, `press("Meta+k")`, `pointer.down/move/up` (the macOS press-drag-release
menus), `waitFor(condition, { capMs })` and `find`. A target is `{ role, name }` (name is a
string or a RegExp), `{ testId }`, `{ text }` or `{ selector }`. `waitFor` checks again on each
DOM mutation, animation end, transition end and frame. It never waits for a fixed time; its cap
only fails a wait that never comes true.

Each action is one step, and the stage measures it. A `waitFor` that does not hold at once is a
step too (what loads while the play waits, older history or a reply, must not move the rows on
screen), and `ctx.resize(width)` resizes the pane as the sidebar toggle does: each box may move
once to its new place, and a second move is a bounce. The stage's load, from navigation to the
play, is measured the same way (`window.cmuxGalleryLoadReport`).

Gallery health gates the layout shift of every state it renders against
`scripts/gallery-matrix/shift-baseline.json`: a state whose row is 0 fails on any shift past frame-timing noise (load plus
steps), a non-zero row fails past its margin, and a state with no row yet only warns. Rows only go
down (`bun shift-baseline.ts --from <artifacts>`); `--add` writes rows for new states.

- anchors: the entry's `anchors` (targets). An anchor the step did not target must not move or
  resize (0 px).
- layout shift: the step's CLS sum and each shift with its source node (0 allowed), and its box
  shift (`shift.ts`): the boxes of the rows a person reads (`[data-row-id]`, the composer, menus,
  list and tree rows, anything marked `data-gallery-track`, and the anchors) sampled every frame
  and scored the way CLS is. Unlike the browser's CLS it sees a move that scrolling made (a
  bottom-pinned transcript scrolling its rows up when a tool expands) and works in WebKit. The
  step's target, rows after it pushed straight down, and boxes still entering do not count.
- action-to-settled latency: wall time from dispatching the gesture until the page settles; the
  matrix reports p50 / p95 / max, and an entry may gate each step with `settleMaxMs` when the
  interaction has a user-facing responsiveness budget. Settling waits on frames, so like the
  long frames below the budget fails only from Chromium's Long Animation Frames timing; a
  WebKit step over it warns with the number.
- long frames: Long Animation Frames (Chromium), else rAF intervals. A frame over 16.7 ms is
  reported (warn). A frame over 33 ms fails only from Chromium's Long Animation Frames data:
  headless WebKit on a CPU-only VM renders in software, and its rAF timing measures the VM. So
  there it only warns ("software-rendered, not a gate"). Real WebKit frame timing comes from the
  native app on a fleet Mac. The anchor and layout-shift checks are strict in both engines.

To loosen a check, the entry or the individual variant writes the value and the reason. Variant
checks override the entry defaults, and `validateEntries` refuses a check without a reason:

```ts
checks: { longFrameFailMs: { value: 50, reason: "The first Shiki highlight compiles its grammar." } },
```

For an interaction with a responsiveness budget, combine the frame checks with a measured settle
budget. The report still records every sample and the matrix shows its p50 / p95 / max values:

```ts
checks: {
  settleMaxMs: { value: 250, reason: "Image viewer actions should settle within a quarter second." },
},
```

The report is `window.cmuxGalleryPlayReport` (and `data-gallery-play` on the stage's root). The
matrix index shows layout shift and long frames cells (pass, warn or fail, with the numbers), plus
action-to-settled p50 / p95 / max latency and sample count when a case has play steps; click a cell
for each step's details. Scroll and text-selection steps are measured alongside clicks, keys and
press-drag gestures. A failing play fails the run. The
checks are real only in the matrix runner (Freestyle or CI). The shell shows the same report as a
live line for the person who opens it.

## Settings and passwords

`pages.settings` and `pages.passwords` fill the full content area (`one` in window mode).
Their width presets exercise narrow and wide standalone panes. Settings variants include every
section and a focused, customized state for each control group below the initial viewport.
`steps` open the real controls through DOM events; the host waits for the requested elements
and fails the stage if an expected form never appears. They do not replace the page components.

Passwords fixtures contain metadata only. This branch has no React import or conflict-review
screen and no vault-lock screen. The `locked` variant shows the page's authentication-failure
notice. Reveal, delete confirmation, and export warning/authentication/save panels are native;
the mock provider exercises their page outcomes without drawing substitute sheets.

## Coverage

`test/gallery-coverage.test.ts` fails when an exported component or a `PageDescriptor` has no entry
and is not in `test/gallery-coverage.allowlist.json`. It also fails when the allowlist names
something an entry now covers. After you add an entry:

```sh
cd webviews
CMUX_GALLERY_UPDATE_ALLOWLIST=1 bun test test/gallery-coverage.test.ts   # shrink the allowlist
bun test test/gallery-coverage.test.ts test/gallery-env.test.ts test/pane-english.test.ts
bun run typecheck
```

The allowlist's `owners` names the lane that writes the entries under a path prefix (Leo's lanes
own the composer pickers, the subagent group, render cards, Sources and Changes, and the docked
chat). Do not write those entries yourself.

## The mock app: the whole window by URL

`mock-app.html` is cmux NEXT's whole window in a browser: the sidebar, each pane's tab strip, and each
pane's real surface (the agent pane with its transcript, composer, menus and Session Info, New Tab,
Home) in its own stage frame, as each pane is its own web view in the app. Only the native parts
around the panes (sidebar, tab strip, traffic lights) are approximated, from the app's metrics
(`MetricTunables.swift`) and the fixture's chats. The gallery shows one entry at a time; the mock
app shows one state of the whole app per URL, which is what the UI judge (review council,
`ui-climb`) and the native preview window drive.

`app.html` ("Whole app" in the shell header, #35270) is the lighter page: one window over the `app.window`
scenes in React. The mock app takes any fixture and every axis below.

```
mock-app.html?fixture=app.window/chat-session-info&window=pro14&density=compact&theme=Catppuccin%20Mocha&script=streaming
mock-app.html?windows=pro14,air13,1280x800&layout=two&fixture2=app.window/new-tab
mock-app.html?fixture=agent-pane.turn-error-card/disk-full&cpu=4&slot=custom-element&colorScheme=light
```

Every key is an axis in `src/gallery/mock-app/axes.ts` (`AXES`). A `frame` axis goes to every pane's
`frame.html` unchanged, so any control a stage reads (env.ts) works here too; a `main pane` axis
goes only to the pane `fixture` names (the panes share one main thread, so a script plays and CPU
contention runs once); an `app` axis shapes the window. Adding an axis the stage already reads is one row in `AXES`; a new script or extension
slot is one entry in `SCRIPTS` or `SLOTS` (`src/gallery/frame/scripts.ts`), and the URL then names
it. `script=` also works on a plain `frame.html` stage.

| Key                                                                                                        | Applies to | What it sets                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fixture`, `fixture2`                                                                                      | app        | the main and second pane: `<entry id>/<variant>` of any agent-pane entry (default `app.window/chat-session-info`, `app.window/new-tab`)                                      |
| `window`, `windows`                                                                                        | app        | the window size (a `WINDOW_PRESETS` name or `<w>x<h>`); `windows=` lists several, each the whole app, side by side (offscreen ones mount as they scroll in)                  |
| `layout`                                                                                                   | app        | `one`, `two` or `agent-right`                                                                                                                                                |
| `sidebar`                                                                                                  | app        | `hidden` hides the sidebar                                                                                                                                                   |
| `zoom`                                                                                                     | app        | `fit` (default) scales each window with one transform; a number is a fixed scale                                                                                             |
| `chrome`                                                                                                   | app        | `web` (default) draws the window frame in the page; `native` lets a native host window (the view shell, `cmux preview open`) draw the frame and glass, and the page fills it |
| `density`, `scale`, `interfaceScale`, `fontFamily`, `fontSize`                                             | frame      | density and size, as in the gallery                                                                                                                                          |
| `theme`, `colorScheme`, `accent`, `background`, `titleAreaTone`, `locale`, `reducedMotion`, `highContrast` | frame      | theme and customization, as in the gallery; the chrome takes the same theme                                                                                                  |
| `script`, `loop`                                                                                           | main pane  | `streaming`, `tools` or `error`: the chat comes alive on a loop through the pane's real `receive` (`loop=0` plays once)                                                      |
| `cpu`                                                                                                      | main pane  | simulated main-thread contention: each pane gets 1/N of its thread (a harness can also throttle with CDP)                                                                    |
| `slot`                                                                                                     | main pane  | `custom-element`: an extension's renderer (a custom element) through the pane's real registry, with a row of its kind                                                        |
| `exp`, `arm`                                                                                               | frame      | an experiment's arm                                                                                                                                                          |

The page sets `data-mock-app-ready="1"` on its root and posts `{type: "cmux-mock-app", status:
"ready"}` to its parent when the first window's panes are ready. It runs no timer or animation
frame while idle (only a `script` or `cpu` does, and those stop while the page is hidden).

Open it from `bun run gallery:dev` at `http://127.0.0.1:4210/gallery/mock-app.html`, from a static build
(`dist/gallery/mock-app.html`), or on the live tailnet gallery (`.../live/mock-app.html`).

### Open-and-idle cost

`scripts/gallery-matrix/app-perf.ts` measures a built gallery in Chrome: first frame, ready, long
tasks after ready, idle CPU (CDP `TaskDuration` over a 5 s window), idle rAF and timer calls per
second with where they came from, JS heap, DOM nodes and layout shift after first paint. The
scenarios and budgets (first frame under 500 ms, no long task over 50 ms after ready, about 0%
idle CPU, no layout shift after first paint) are in `app-perf-budgets.json`. It is lane-run, not a
CI gate: run it before and after a change and put its `table.md` in the PR.

```sh
cmux-ci test --setup playwright --artifact /tmp/perf -- bash -c '
  cd webviews && bun install --frozen-lockfile && CMUX_GALLERY_OUT_DIR=$PWD/../dist-gallery bun run gallery:build &&
  cd ../scripts/gallery-matrix && bun install --frozen-lockfile &&
  eval "$(../ci/ensure-system-chrome.sh | grep ^CMUX_CHROME_HEADLESS_SHELL= | sed "s/^/export /")";
  bun app-perf.ts --gallery-dir ../../dist-gallery --out "$FAST_CHECKS_OUT" --cpu 4'
```

## The golden screen: every look side by side

`looks.golden` (`src/gallery/golden/golden.gallery.ts`) is one chat that holds every part a look
changes: a prompt bubble, a reply with headings, a list, inline code, a code block and a link, tool
rows done, failed and running, the edited-files card, a permission prompt with its diff, and the
composer with its chips and a draft. In the mock app the window around it adds the sidebar's two
projects (a selected, a waiting, a working, an unread and a failed chat, ages where the look shows
them) and a strip of four tabs. Each variant is one look of `src/gallery/golden/looks.json`; the
stage's `colorScheme` picks the look's light or dark theme file.

A look there is what a setup carries: per scheme a theme file (a repo path, or its keys inline),
`settings` (`agentPane.*` go to the chat's `display` push, `sidebar.*` to the mock window), a
composer look, and an `agent-pane/theme.css`; or `setup`, a setup folder (`examples/looks/NAME`). The
dev server resolves it (`dev-server/goldenLooks.ts`, `virtual:cmux-gallery/looks`); a look whose files
this checkout lacks is skipped. A variant of any agent-pane entry can carry a `look` the same way.

`bun run golden:looks` captures each look in light and dark in the mock app's window and writes
`sheet.png` with every look side by side. A look PR posts it from its base and its head:

```sh
cmux-ci test --setup playwright --artifact /tmp/golden -- bash -c 'cd webviews && bun install --frozen-lockfile &&
  bun run golden:looks --out "$FAST_CHECKS_OUT/golden"'
bun run golden:looks --looks cmux,codex --setup ~/src/my-look   # an outside look beside the built-in ones
bun run golden:looks --native DIR   # adds the native sidebar and tab bar (AAGoldenLookGalleryTests' PNGs) per look
bun run golden:looks --settings appearance,chat   # adds the golden Settings page per look (below)
bun run golden:looks --every        # every look the checkout carries, as the contrast test draws them
bun run golden:looks --setup ~/src/my-look --preview   # also writes ~/src/my-look/preview/golden-{light,dark}.png, the stills the Settings looks gallery shows
```

The golden Settings page (`looks.golden.settings.appearance` and `looks.golden.settings.chat`,
`src/gallery/golden/settings.ts`) is the real Settings page under each look, from the same looks: the
scheme's theme file themes the page and answers as the named theme's colors, and the look's settings,
composer look and theme file keys are the values the rows show (`lookSettingsValues` in
`src/gallery/golden/look.ts`). Appearance holds a look's own rows; Chat is a long section with the
chat's display rows. `--settings` captures each section whole beside the golden screen, in the sheet.

With `--settings`, each look also gets a window scene (`<look>-window-<section>-<scheme>.png`,
`--settings-window 1920x1200`): the mock app with the golden chat and that Settings section side by
side, both under the look. The pane contents are the real web components; the sidebar, tab strips
and traffic lights are the mock app's web stand-in for native chrome, marked `data-stand-in` in the
DOM and captioned so in the sheet. What only native draws is left out rather than faked: the
expanded sidebar density, `sidebar.sectionLook`, and the tab bar's margin and title-area tones.

`looks.golden-menus` (`src/gallery/golden/GoldenMenus.gallery.tsx`) is the golden screen's menus and
popover, which portal outside the chat: an open menu with a section label, shortcuts, an open submenu,
a disabled and a red destructive row, beside the plan usage popover, a variant per look.

The golden screen is the sample every look's contrast is checked on (`test/browser/golden-look-contrast-{0,1,2,3}.test.ts` (one suite, `test/support/goldenLookContrastSuite.ts`)):
both entries under every look the checkout carries, found rather than listed (`discoverLooks`: each
shipped theme file, each setup folder and theme file under `examples/`, past the registry), in each
scheme it draws. Every text under 4.5:1 (3:1 large text and icons) fails with its look, element, text,
colors and ratio, past the default chat's known pairs (`test/support/contrastKnown.ts`).

## Seeing it

- Static: from `webviews`, `bun run gallery:build` writes `dist/gallery`.
- Dev: `bun run dev`, then `http://127.0.0.1:4200/gallery/` (`CMUX_WEBVIEWS_DEV_PORT` moves it), or
  `bun run gallery:dev` for the gallery alone at `http://127.0.0.1:4210/gallery/`.
- Live, with hot reload (tailnet): `https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/live/`
  follows `feat-cmux-next` within about 20 s of a push. A save shows in the open page by itself.
- Shell-generated `frame.html` stages include their gallery source path and load only that entry;
  direct `frame.html?entry=...` links without the optional source hint fall back to the full
  registry and show an explicit loading state while unrelated gallery modules compile.
- Your branch before it lands: `scripts/gallery-live.sh up <branch>` in hq serves the pushed branch
  at `.../18796/wt/<name>/` (it prints the URL) and follows its pushes; it stops after 2 h with no
  requests. At most 6 run at once; `scripts/gallery-live.sh down <name>` stops one.
- Static (the stable fallback): `scripts/gallery-deploy.sh` in hq publishes a build at
  `https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/latest/`.
- Screenshots: `bun scripts/gallery/manifest.ts --entries <your id>` writes a manifest, and
  `scripts/gallery-matrix/runner.ts --freestyle-vms N` renders it on Freestyle VMs. Never run a
  browser on a developer laptop.

## Viewer picks

An entry opts into tracker comments with
`pick: { beadId: "cx-czd", recommendedId: "a" }`. In **All variants**, the gallery
uses `ui/variant-pick/VariantPick` for side-by-side previews, one Recommended
badge, and Pick buttons. Arrow keys move between buttons; Return records the
choice. The optional note is limited to 500 characters. Other gallery views keep
their existing stage behavior. Entries without a related bead remain read-only.

`ui.variant-pick` demonstrates gallery, thread, and five-option layouts. Picks
inside its fixture previews are local, including its play step. Only the outer
gallery comparison writes a real comment to `cx-czd` through `/api/pick`.
The gallery cannot confirm a pick until the lead installs the reviewed endpoint.
The feed sink is a no-op pending Leo's integration; no feed post is claimed.
See `src/ui/variant-pick/README.md` for the common API and in-thread adapter.

## Experiments: compare alternative implementations

An experiment is a named set of alternative implementations ("arms") of one behavior or look, so
Lawrence can see them side by side and pick one. Three pieces, all next to the component:

1. The definition, `<name>.experiment.ts`: `defineExperiment({ id, title, description, arms,
   defaultArm })` from `src/experiments/experiment.ts`. Each arm has a `label` and a one-line
   `description`. `defaultArm` is the arm that ships. Export it (`export const`): the file is all
   `src/experiments/registry.ts` needs, which finds every `*.experiment.ts(x)` on its own.
2. The component reads its arm with `experimentArm(definition)`. The arm comes from one place: the
   host override `globalThis.cmuxExperiments` (the gallery's stage frame sets it from `arm=`), else
   the debug key `localStorage["cmux.experiments"]` (`{"<id>":"<arm>"}`, for dogfood in the app),
   else `defaultArm`. Keep each arm's code path separate, so a losing arm is one deletion.
3. The gallery entry gets `experiment: { definition, setup?, script, measurements? }`. `script` is
   a list of named steps (`{ name, run: (ctx) => ... }`, the play context of play.ts; `{ deep:
   selector }` targets elements inside open shadow roots). `setup` brings the stage to the start
   state with every animation finished at once.

The entry then has a **Compare arms** view. Each cell is the same variant at the same size, scale,
theme and locale, labeled with its arm id and description. **Replay all** reloads every cell and
runs the script in all of them in lockstep: step N starts in every cell at the same time, and step
N+1 waits until every cell has finished step N. **Next step** and **Previous step** walk the
script. Speed (0.1x to 1x) slows every Web Animation in the cells. **Enlarge** shows one cell at the
largest fit. **Pick** marks an arm. All of it is in the URL:

```
#/<entry>/<variant>?view=compare&arms=a,c,e&grid=3&speed=0.5&loop=1&focus=c&pick=c&step=2&theme=...
```

`arms` (default: every arm), `grid` (`auto` wraps, `row`, `1`, `2`, `3` columns), `speed`, `loop`,
`focus` (the enlarged arm), `pick`, `step` (the cells rest after that many steps), plus the usual
controls (env.ts). **Copy link** copies the URL with a one-line summary under it (for example
`experiment diff-tree-disclosure, entry agent-pane.changes-tree/many-files, arms a,c,e, speed
0.5x, step 2 of 4 (open nested B), picked c`), so the link reads clearly in chat. An agent given
the link reads the same keys with `readCompare` (`src/gallery/compare.ts`).

Each cell shows two measurement lines: `VM ...`, the numbers a matrix run measured on a Freestyle
VM (the entry's `measurements`), and `here, last step ...`, the frames the viewer's own browser
measured. Both lines also report action-to-settled p50, p95 and max for clicks, keys and press-drag
pointer steps. An arm reports its main-thread planning with `performance.measure("cmux-motion:...")`;
the harness shows the largest as `plan`.

Measuring on Freestyle (never a browser on a laptop):

```sh
cd webviews && bun scripts/gallery/manifest.ts --experiments --entries <entry id> --out /tmp/exp.json
cd ../scripts/gallery-matrix && bun runner.ts --manifest /tmp/exp.json --gallery-dir ../../webviews/dist/gallery \
  --output-dir /tmp/exp-run --engines chromium --freestyle-vms 6
bun experiments.ts --output-dir /tmp/exp-run --run <name> --publish   # strips/, experiments.json, experiments.html
```

`--experiments` writes, per arm, one `measure=1` case (the script at 1x; frame intervals,
action-to-settled latency and planning time per step) and a frame strip (`freeze=<step>:<ms>` pauses every animation that many ms
after the step's input). Copy the arm numbers from `experiments.json` into the entry's
`measurements`. To ship the winner, set `defaultArm`, then delete the other arms' code and the
experiment (registry line, definition, gallery `experiment`) once the choice is final.
