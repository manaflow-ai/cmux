# Recipe: a command (palette, CLI and agent tool)

One operation that runs from the Command Palette, as `cmux greet hello NAME` in a terminal,
and as a tool agents can call. It is declared in `catalog.json`; the manifest names the file.

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-command",
  "name": "Greet",
  "version": "0.1.0",
  "description": "Says hello.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "dist/main.js" },
  "catalog": "catalog.json",
  "cli": { "name": "greet" },
  "files": ["dist/", "catalog.json"]
}
```

`catalog.json` (the family is the id with `/` as `.` and `-` as `_`; the owner is `app:` and the id):

```json catalog.json
{
  "family": "local.recipe_command",
  "operations": [
    {
      "name": "local.recipe_command.hello",
      "owner": "app:local/recipe-command",
      "class": "read",
      "risk": "read",
      "idempotency": "forbidden",
      "docs": "Says hello in a toast and returns the greeting.",
      "since": "0.1.0",
      "export": "hello",
      "input": {
        "type": "object",
        "additionalProperties": false,
        "properties": { "name": { "type": "string", "description": "Who to greet." } }
      },
      "output": { "type": "object", "properties": { "greeting": { "type": "string" } } },
      "cli": { "path": "hello", "positional": ["name"] },
      "mcp": { "expose": "default" },
      "palette": { "title": "Greet: Say hello" }
    }
  ]
}
```

`src/main.ts`:

```ts src/main.ts
import { command } from "cmux-extension-sdk"

// The export catalog.json names. args match `input`; the return matches `output`.
export const hello = command(async (args: { name?: string }, { cmux }) => {
  const greeting = `Hello, ${args.name ?? "you"}`
  await cmux.toast({ title: greeting, tone: "success" })
  return { greeting }
})
```

Rules: `cli.name` is 2 to 24 lowercase letters, digits and dashes and not a cmux command; a
write (`class: "write"`) asks before it runs; keep `input` closed (`additionalProperties: false`).

```sh
cmux ext dev --once --json
cmux greet hello Ada
```

<!-- recipe-check: loads -->
Exit 0 (a command draws no view, so `scene` is empty); then the toast says Hello, Ada.
