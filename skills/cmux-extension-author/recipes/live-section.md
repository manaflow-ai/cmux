# Recipe: a live section with a signal

A sidebar section that lists your workspaces and redraws when one changes, with no timer.
Interface: `cmux.section/1`; data: `cmux.watch("workspace.list")`
(signals: [`schema/v2/signals.json`](../../../cmux-tui/crates/cmux-app-host/schema/v2/signals.json)).

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-live-section",
  "name": "Spaces",
  "version": "0.1.0",
  "description": "Your workspaces, live.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "dist/main.js" },
  "implements": {
    "cmux.section/1": { "export": "renderSection", "title": "Spaces", "symbol": "rectangle.stack" }
  },
  "scopes": { "workspace:read": "List your workspaces." },
  "files": ["dist/"]
}
```

`src/main.ts`:

```ts src/main.ts
import { cmux, EmptyState, ForEach, ProgressView, Row, section, Text, VStack } from "cmux-extension-sdk"

export const renderSection = section(() => {
  // One cached read for every section that asks; re-read when cmux pushes workspace.changed.
  const spaces = cmux.watch("workspace.list")
  const list = () => spaces.value() ?? []
  return VStack([
    Text(() => `${list().length} workspaces`).font("caption").color("secondary"),
    ForEach({ items: list, key: (w) => w.id }, (w) =>
      Row({ title: () => w().name, symbol: () => (w().focused ? "rectangle.inset.filled" : "rectangle") })
    ),
    () => {
      if (spaces.status() === "loading") return ProgressView()
      if (spaces.status() === "error") return EmptyState({ title: "Can't read workspaces", symbol: "exclamationmark.triangle" })
      return null
    },
  ])
})
```

Rules: `cmux.watch` (or `workspaces()`, `agents()`, `chats()` from the SDK) instead of
`cmux.timer.every` polling; draw the loading and error states; read scopes such as
`workspace:read` are granted at install.

```sh
cmux ext dev --once --json
```

<!-- recipe-check: shows "workspaces" -->
Exit 0, and `scene` has a `Text` ending in `workspaces`.
