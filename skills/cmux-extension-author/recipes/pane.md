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

Rules: one pane per extension; it opens with no arguments; keep what must survive a reload in
`cmux.storage` (scope `storage:local`), not in a global.

```sh
cmux ext dev --once --json
```

<!-- recipe-check: shows "Notes pane" -->
Exit 0, and `scene` has `Text text="Notes pane"`. Open it with Notes in the Command Palette.
