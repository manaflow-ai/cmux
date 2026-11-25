# Recipe: a keyboard shortcut

A shortcut that runs one of the extension's own catalog ops. `contributes.keybindings` binds the
chord; the op's export is the handler (`onKeybinding`). cmux lists the chord with the app's
commands, so it runs above cmux's defaults and below the person's `keybindings.json`, and the op
also shows in the Command Palette under the keybinding's `title`.

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-keybinding",
  "name": "Shortcut",
  "version": "0.1.0",
  "description": "Says hi on cmd+shift+y.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "dist/main.js" },
  "catalog": "catalog.json",
  "activation": ["onKeybinding:say-hi"],
  "contributes": {
    "keybindings": [
      { "id": "say-hi", "key": "cmd+shift+y", "op": "local.recipe_keybinding.say_hi", "title": "Shortcut: Say hi" }
    ]
  },
  "files": ["dist/", "catalog.json"]
}
```

`catalog.json`:

```json catalog.json
{
  "family": "local.recipe_keybinding",
  "operations": [
    {
      "name": "local.recipe_keybinding.say_hi",
      "owner": "app:local/recipe-keybinding",
      "class": "read",
      "risk": "read",
      "idempotency": "forbidden",
      "docs": "Says hi in a toast.",
      "since": "0.1.0",
      "export": "sayHi",
      "input": { "type": "object", "additionalProperties": false }
    }
  ]
}
```

`src/main.ts`:

```ts src/main.ts
import { onKeybinding } from "cmux-extension-sdk"

// The export the op names; the shortcut runs it.
export const sayHi = onKeybinding(async (_args, { cmux }) => {
  await cmux.toast({ title: "Hi", tone: "success" })
})
```

Rules: `key` holds `cmd`, `ctrl` or `alt` (`option`) plus one key, lowercase (`cmd+shift+y`,
`ctrl+alt+k`); a bare key or `shift+key` would take typing and is refused, and so are system
chords (`cmd+q`, `cmd+h`, `cmd+m`, `cmd+tab`, `cmd+space`). `op` is an op of this extension's own
catalog. `when` (optional) is a context clause such as `agentPaneFocused`. At most 16 bindings.
`onKeybinding:<id>` must name a declared binding. The person can rebind or unbind it in
`keybindings.json` with the command `app.command.run`.

```sh
cmux ext dev --once --json
```

<!-- recipe-check: loads -->
Exit 0 (a shortcut draws no view, so `scene` is empty); then cmd+shift+y shows the Hi toast.
