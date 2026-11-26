# Recipe: a pane

A view of your own in a tab, opened from the Command Palette by its title.
Interface: `cmux.pane/1`
([contract](../../../cmux-tui/crates/cmux-app-host/interfaces/cmux.pane/1.json)).

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-pane",
  "name": "Notes",
  "version": "0.1.0",
  "description": "A notes tab.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "dist/main.js" },
  "implements": {
    "cmux.pane/1": { "export": "renderPane", "title": "Notes", "symbol": "note.text" }
  },
  "files": ["dist/"]
}
```

`src/main.ts`:

```ts src/main.ts
import { Button, computed, Panel, pane, signal, Text, VStack } from "cmux-extension-sdk"

const [count, setCount] = signal(0)
const label = computed(() => (count() === 1 ? "1 note" : `${count()} notes`))

export const renderPane = pane(() =>
  VStack([
    Panel({ title: "Notes" }, [
      Text("Notes pane").font("title2").weight("semibold"),
      Text(label).color("secondary"),
      Button("Add a note", () => setCount((n) => n + 1)),
    ]),
  ])
)
```

Rules: one pane per extension; view state that must survive a hot reload goes in `ctx.keep`
(below), what must survive closing the pane or a relaunch in `cmux.storage` (scope
`storage:local`), never in a global.

## Keep view state across a hot reload

`ctx.keep(name, initial)` is a `signal` ([read, write]) whose value cmux keeps with the view. A
`cmux ext dev` save, a host restart or a Reload renders the view again with it; closing the view
forgets it. `ctx.state` holds every kept value the view got back. Values are JSON, at most 64 KiB
together. Every view's context has it (a section, a pane, a widget); it needs no scope.

```ts
import { Button, pane, Text, VStack } from "cmux-extension-sdk"

export const renderPane = pane((ctx) => {
  const [tab, setTab] = ctx.keep("tab", "open")
  const [expanded, setExpanded] = ctx.keep("expanded", [] as number[])
  return VStack([
    Text(() => `Showing ${tab()} issues, ${expanded().length} expanded`),
    Button("Closed", () => setTab("closed")),
    Button("Expand #42", () => setExpanded((ids) => [...ids, 42])),
  ])
})
```

## Open it with arguments and get a result (a panel flow)

Another view of the same extension (a section, a command, a widget) opens the pane with arguments
and waits for what it returns. `cmux.app.openPane(args)` needs the person's gesture (call it from the
click's handler before any `await`, or pass `{ gesture }`), opens the tab, and resolves
`{ result, dismissed }`:

- the pane calls `ctx.close(result)`: `{ result, dismissed: false }` (the tab stays open; closing
  it is the person's);
- the person closes the tab, or another `openPane` replaces this one: `{ result: null, dismissed: true }`.

In the pane, `ctx.args` is the open's arguments (`null` when the person opened it from the
palette), `ctx.onOpen(fn)` runs with them on each open, and `ctx.onClose(fn)` runs when the pane
goes. An open while the pane is showing mounts it again with the new arguments. `args` and
`result` are JSON objects of at most 16 KiB.

```ts
import { Button, pane, section, Text, VStack } from "cmux-extension-sdk"

export const renderSection = section((ctx) =>
  Button("Pick an issue", async () => {
    const { result, dismissed } = await cmux.app.openPane({ repo: "acme/web" })
    if (!dismissed) await cmux.notify({ title: `Picked ${result.id}` })
  })
)

export const renderPane = pane((ctx) =>
  VStack([
    Text(ctx.args ? `Issues in ${ctx.args.repo}` : "Issues"),
    Button("#42", () => ctx.close({ id: 42 })),
  ])
)
```

```sh
cmux ext dev --once --json
```

<!-- recipe-check: shows "Notes pane" -->
Exit 0, and `scene` has `Text text="Notes pane"`. Open it with Notes in the Command Palette.
