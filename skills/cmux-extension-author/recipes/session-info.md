# Recipe: a Session Info section

A section in an agent chat's Session Info panel, about that chat's session.
Interface: `cmux.session.info.section/1`
([contract](../../../cmux-tui/crates/cmux-app-host/interfaces/cmux.session.info.section/1.json)).

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-session-info",
  "name": "Where",
  "version": "0.1.0",
  "description": "The chat's folder and branch.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "dist/main.js" },
  "implements": {
    "cmux.session.info.section/1": {
      "export": "renderSessionInfo",
      "title": "Where",
      "symbol": "folder",
      "options": { "maxRows": 4 }
    }
  },
  "files": ["dist/"]
}
```

`src/main.ts`:

```ts src/main.ts
import { Row, section, VStack } from "cmux-extension-sdk"

// The context is the chat's session: { session_id, cwd?, branch?, harness? }.
export const renderSessionInfo = section((context) => {
  const session = context as { cwd?: string; branch?: string }
  return VStack([
    Row({ title: session.cwd ?? "No folder", subtitle: "Folder", symbol: "folder" }),
    Row({ title: session.branch ?? "No branch", subtitle: "Branch", symbol: "arrow.triangle.branch" }),
  ])
})
```

Rules: draw the missing case of every field (a chat may have no folder); keep to `maxRows`.

```sh
cmux ext dev --once --json
```

<!-- recipe-check: shows "Branch" -->
Exit 0, and `scene` has `Row title="No branch"` (the check mounts it with no session).
