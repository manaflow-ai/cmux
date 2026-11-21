# json-render widgets: a prototype

An agent describes a widget as a [json-render](https://github.com/vercel-labs/json-render) spec,
using only the parts in `catalog.json`. cmux draws the spec with its own extension kit, so the
widget looks the same on every renderer the kit has (AppKit on the Mac, React in the web pages).
This folder uses json-render's spec format and prompt. It does not ship json-render's React or
SwiftUI renderers.

- **Catalog** (`catalog.json`): 12 parts: Panel, Stack, Text, Row, Button, TextField, Toggle,
  Badge, ProgressView, EmptyState, Divider and Spacer. It also lists the three state actions
  (setState, pushState, removeState) and the limits on a spec's size.
- **Check** (`src/check.ts`): refuses a spec whose part, prop, event or action is not in the
  catalog. It also refuses a child that does not exist, a cycle, and a spec past the limits. A
  refused spec draws nothing; the widget says why instead.
- **Draw** (`src/spec.ts`): turns each element into a kit view and binds it to the spec's state.
  It supports `$state`, `$bindState`, `$item`, `$bindItem`, `$index`, `$cond`, `$template`,
  `visible` and `repeat`.
- **Sidebar section**: shows `specs/todo.json`, or the spec you pinned. Its state, your todos, is
  kept in `cmux.storage`.
- **Chat widget** (`cmux.chat.widget/1`): an agent sends a widget part,
  `{type: "widget", app: "local/json-render", props: {spec}, fallback}`, and the card draws the
  spec. "Pin to sidebar" makes it the sidebar widget.

## How the todo widget was made

```sh
cd generate && bun install --ignore-scripts
bun generate.ts "make me a todo widget" ../specs/todo.json
```

`generate.ts` does four things:

1. It turns `catalog.json` into json-render's own catalog (Zod props) and builds the prompt with
   `catalog.prompt()`. The prompt is about 17 KB; `specs/todo.prompt.txt` holds it.
2. It asks Claude through the `claude` CLI, which answers in json-render's JSONL patch stream
   (`specs/todo.jsonl`).
3. It folds the patches into a spec with json-render's `createSpecStreamCompiler`.
4. It runs `check()` on the spec.

The run that made `specs/todo.json` used claude-sonnet-5-5. It took 9.2 s and made 22 patches and
15 elements, and `check()` found no issues.

## Run it

```sh
cmux ext dev --once      # build, install and load it into the running cmux
cmux ext shot --out widget.png
```

Tests: `cmux-tui/crates/cmux-app-host/js/test/examples.test.ts` ("local/json-render").
Render cost: `bun bench/render-cost.ts`.
