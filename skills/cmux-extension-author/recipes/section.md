# Recipe: a sidebar section

A section in the sidebar that lists three things and toasts on a click.
Interface: `cmux.section/1`
([contract](../../../cmux-tui/crates/cmux-app-host/interfaces/cmux.section/1.json)).

In a new, empty folder, write two files.

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-section",
  "name": "Today",
  "version": "0.1.0",
  "description": "Three things for today, in the sidebar.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "dist/main.js" },
  "implements": {
    "cmux.section/1": {
      "export": "renderSection",
      "title": "Today",
      "symbol": "checklist",
      "options": { "defaultRegion": "bottom" }
    }
  },
  "files": ["dist/"]
}
```

`src/main.ts`:

```ts src/main.ts
import { cmux, ForEach, Row, section, signal, VStack } from "cmux-extension-sdk"

const [items] = signal(["Review pull requests", "Answer the design thread", "Write the release notes"])

// The export the manifest names. cmux calls it once per mount; signals redraw what reads them.
export const renderSection = section(() =>
  VStack([
    ForEach({ items, key: (title) => title }, (title) =>
      Row({ title: () => title(), symbol: "circle" }).onTap(() => cmux.toast({ title: title(), tone: "success" }))
    ),
  ])
)
```

Rules: state in `signal`, never a timer that redraws; `Row` and the kit, no sizes or colors
of your own; the section header already shows the manifest's `title`.

Prove it (the folder needs no `npm install`; `cmux ext dev` builds `dist/main.js` against the SDK in the CLI):

```sh
cmux ext dev --once --json
```

<!-- recipe-check: shows "Review pull requests" -->
Exit 0, `"ok": true`, and `scene` has `Row title="Review pull requests"`.
