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
| `agentPaneEntry`     | the whole agent pane (`acpmux/main.tsx`) on the pane bridge     | `{ ready?, snapshot }`: the `ready` answer fields and an `AcpmuxSnapshot`                                                       |
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

`ctx` has `click`, `hover`, `focus`, `type(text, target?)`, `press("Meta+k")`,
`pointer.down/move/up` (the macOS press-drag-release menus), `waitFor(condition, { capMs })` and
`find`. A target is `{ role, name }` (name is a string or a RegExp), `{ testId }`, `{ text }` or
`{ selector }`. `waitFor` checks again on each DOM mutation, animation end, transition end and
frame. It never waits for a fixed time; its cap only fails a wait that never comes true.

Each action is one step, and the stage measures it:

- anchors: the entry's `anchors` (targets). An anchor the step did not target must not move or
  resize (0 px).
- layout shift: the step's CLS sum and each shift with its source node (0 allowed).
- long frames: Long Animation Frames (Chromium), else rAF intervals. A frame over 16.7 ms is
  reported (warn). A frame over 33 ms fails only from Chromium's Long Animation Frames data:
  headless WebKit on a CPU-only VM renders in software, and its rAF timing measures the VM. So
  there it only warns ("software-rendered, not a gate"). Real WebKit frame timing comes from the
  native app on a fleet Mac. The anchor and layout-shift checks are strict in both engines.

To loosen a check, the entry writes the value and the reason, and `validateEntries` refuses a
check without a reason:

```ts
checks: { longFrameFailMs: { value: 50, reason: "The first Shiki highlight compiles its grammar." } },
```

The report is `window.cmuxGalleryPlayReport` (and `data-gallery-play` on the stage's root). The
matrix index shows a layout shift cell and a long frames cell (pass, warn or fail, with the
numbers) for each case; click a cell for each step's details. A failing play fails the run. The
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
bun test test/gallery-coverage.test.ts test/gallery-env.test.ts test/gallery-theme.test.ts test/pane-english.test.ts
bun run typecheck
```

The allowlist's `owners` names the lane that writes the entries under a path prefix (Leo's lanes
own the composer pickers, the subagent group, render cards, Sources and Changes, and the docked
chat). Do not write those entries yourself.

## Seeing it

- Static: from `webviews`, `bun run gallery:build` writes `dist/gallery`.
- Dev: `bun run dev`, then `http://127.0.0.1:4200/gallery/` (`CMUX_WEBVIEWS_DEV_PORT` moves it), or
  `bun run gallery:dev` for the gallery alone at `http://127.0.0.1:4210/gallery/`.
- Live, with hot reload (tailnet): `https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/live/`
  follows `feat-cmux-next` within about 20 s of a push. A save shows in the open page by itself.
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
   `description`. `defaultArm` is the arm that ships. Add the definition to
   `src/experiments/registry.ts` (one import, one list item); `test/experiments.test.ts` checks it.
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
