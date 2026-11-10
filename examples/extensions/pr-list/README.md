# Recipe: a live sidebar section

`example/pr-list` is a sidebar section with your open pull requests and the ones waiting for your
review, kept live by `cmux.watch("github.pulls")`. It uses only the public app API, so it is also
the template for any live section: copy the folder, change the id, the watch and the rows.

## 1. The manifest (`cmux-app.v2.json`)

- `id` in your own namespace (`<you>/<name>`), `manifestVersion: 2`, `runtime.main: "dist/main.js"`.
- `implements["cmux.section/1"]`: the render `export`, a `title`, a `symbol`, and
  `options.defaultRegion` (`top`, `middle` or `bottom`: where it starts; the person moves it).
- `scopes`: what the source needs (`cmux.watch` lists them per source in
  `cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`, `CmuxSignalMap`; here
  `integration:github:read`) plus `actions:run` to open a link. `optionalScopes` for a fallback.
- `catalog`: `catalog.json` declares the Refresh command as an op (`example.pr_list.refresh`); its
  `palette.title` puts "PR List: Refresh" in the command palette and `cli.path` makes it
  `cmux example.pr_list refresh`.

## 2. The section (`src/main.ts`)

```ts
export function renderPullRequests() {
  // One read however many windows show this section; polled behind the signal at the source's
  // budget; stops when the section is gone. Params as a function follow a setting.
  const prs = cmux.watch("github.pulls", () => ({ roles: ["review-requested", "author"] }))
  return VStack([
    ForEach({ items: () => prs.value() ?? [], key: (p) => p.id }, (p) =>
      Row({ title: () => p().title, subtitle: () => `${p().repo} #${p().number}` }).onTap(() =>
        cmux.actions.run("openBrowser", { url: p().url })
      )
    ),
    () => (prs.status() === "error" ? EmptyState({ title: "Can't load", message: prs.error()?.message }) : null)
  ])
}

export async function refresh() {
  return { count: (await cmux.watch.refresh("github.pulls", { roles: ["review-requested", "author"] })).value?.length ?? 0 }
}
```

`prs()` is `{ value, status, error?, updatedAt }`; `prs.value()`, `prs.status()`, `prs.error()`,
`prs.updatedAt()` read one field each, so a status change does not touch the rows. Status is
`loading` (no value yet), `fresh`, `stale` (the old value is shown while it is re-read, or after a
re-read failed: `error` says why) or `error` (no value). This example dims the list and shows a
"Couldn't refresh" row when it is stale with an error, and an empty state on `error`.

Do not add `cmux.timer.every` polling: the runtime polls only sources nothing pushes, never faster
than the source's `pollFloorSeconds`, backs off on errors, and keeps one read per (source, params)
for every section of the app. The contract is `cmux-tui/crates/cmux-app-host/js/ABI.md`, Signals.

## 3. Build, check, run

```sh
bun examples/extensions/build.ts           # packs dist/main.js, validates the manifest and catalog
bun examples/extensions/build.ts --check   # what the app platform gate runs
```

To run it, copy the built folder into the daemon's local development folder (`<state>/apps/local/`):
it hot-reloads on save, keeping the last good script if a save does not load.

Tests: `cmux-tui/crates/cmux-app-host/js/test/examples.test.ts` mounts it in the fake host.

## Placing the section

A section starts in its `defaultRegion`; `cmux apps place 'example/pr-list#cmux.section/1' --region
top|middle|bottom` moves it. The person drags it by its header among the sections of the top and
bottom regions, and between those two regions. In the middle region it is not yet draggable
around the workspace list.
