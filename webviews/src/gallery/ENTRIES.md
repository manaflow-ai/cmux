# Adding gallery entries

One entry is one file, `<Name>.gallery.ts` (or `.tsx`), next to the page or component it shows. Its
default export is the entry. The gallery finds every such file under `webviews/src` by itself
(`src/gallery/registry.ts` in the browser, `scripts/gallery/entries.ts` in tests). There is no list
to edit.

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
- Optional: `height` (the component-mode stage height), `widths` (pane widths for component mode),
  and a variant's `note` (one line in the stage header).

The host decides how the real code receives the data:

| helper               | host                                                            | a variant is                                                              |
| -------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `agentPaneEntry`     | the whole agent pane (`acpmux/main.tsx`) on the pane bridge     | `{ ready?, snapshot }`: the `ready` answer fields and an `AcpmuxSnapshot` |
| `markdownPageEntry`  | the markdown page entry on an in-page cmuxPage host             | `{ path, text, readOnly?, settings?, files? }`                            |
| `diffPageEntry`      | the diff page entry on an in-page cmuxPage host                 | `{ files: [{ path, before?, after? }] }` or `{ patch }`, `layout?`        |
| `settingsPageEntry`  | the settings page on its real mock provider through cmuxPage    | `{ section, focus?, options?, host?, accounts?, steps? }`                 |
| `passwordsPageEntry` | the passwords page on its real mock provider through cmuxPage   | `{ data, loading?, authenticate?, failure?, steps? }`                     |
| `componentEntry`     | one React component under `UiProvider` and the page base styles | `{ props }`, plus `load: () => import(...)`                               |
| `nativeEntry`        | the native gallery only (CmuxNextGallery)                       | `{ fixture }`: a repo path of a Swift model's JSON                        |

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

Window mode is the default view. The entry renders at its real size in the pane that `Panes`
selects (`one`: the whole content area; `two`: the left pane; `agent-right`: the right column).
The window around it has its real size (16:9 by default), and the shell scales the finished
window down with one transform. A full-page surface (settings, a page tab) uses `one`. The pane
size comes from the app's metrics (`MetricTunables.swift` for each density), so you add nothing
for window mode. `component` mode shows the entry alone at a pane width, for close work.

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
- Dev: `bun run dev`, then `http://127.0.0.1:4200/gallery/` (`CMUX_WEBVIEWS_DEV_PORT` moves it).
- Shared: `scripts/gallery-deploy.sh` in hq publishes a build at
  `https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/latest/`.
- Screenshots: `bun scripts/gallery/manifest.ts --entries <your id>` writes a manifest, and
  `scripts/gallery-matrix/runner.ts --freestyle-vms N` renders it on Freestyle VMs. Never run a
  browser on a developer laptop.
