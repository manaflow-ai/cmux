# Recipe: a whole New Tab page

Your own New Tab page. It shows only after the person picks it.
Interface: `cmux.newtab/1`
([contract](../../../cmux-tui/crates/cmux-app-host/interfaces/cmux.newtab/1.json)).

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-newtab",
  "name": "Start",
  "version": "0.1.0",
  "description": "A plain New Tab page.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "dist/main.js" },
  "implements": {
    "cmux.newtab/1": { "export": "renderNewTab", "title": "Start", "symbol": "house" }
  },
  "files": ["dist/"]
}
```

`src/main.ts`:

```ts src/main.ts
import { newTab, Panel, Row, Text, VStack } from "cmux-extension-sdk"

// The context: { surface: "newTab", cwd? }, the folder the tab starts in.
export const renderNewTab = newTab(({ cwd }) =>
  VStack({ spacing: 12 }, [
    Panel([
      Text("Good to see you").font("largeTitle").weight("semibold"),
      Text(cwd ?? "Your home folder").font("callout").color("secondary"),
    ]),
    Panel({ title: "Start" }, [Row({ title: "New agent chat", symbol: "sparkles" })]),
  ])
)
```

Rules: it replaces cmux's page only after `cmux settings set tabs.newTabApp local/recipe-newtab`
(unset it to get cmux's page back); a row's tap runs an action with `cmux.actions.run` and needs
`actions:run`, which the person turns on.

```sh
cmux ext dev --once --json
```

<!-- recipe-check: shows "Good to see you" -->
Exit 0, and `scene` has `Text text="Good to see you"`; `placed` says it shows once picked.
