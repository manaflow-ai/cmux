# Recipe: a slash command in the agent chat composer

A `/standup` row in the composer's `/` menu; picking it writes its text over the typed word.
Interface: `cmux.composer.command/1`
([contract](../../../cmux-tui/crates/cmux-app-host/interfaces/cmux.composer.command/1.json)).
The daemon lists it from the manifest, so there is no script: the manifest is the whole extension.

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-composer-command",
  "name": "Standup",
  "version": "0.1.0",
  "description": "A /standup command for the agent chat.",
  "engines": { "cmux": "^2.0" },
  "implements": {
    "cmux.composer.command/1": {
      "title": "Standup",
      "options": {
        "commands": [
          { "name": "standup", "description": "Ask for today's standup notes", "insert": "Write my standup: what I did yesterday, what I do today, what blocks me." },
          { "name": "review-pr", "description": "Review a pull request", "hint": "<number>", "insert": "Review pull request #" }
        ]
      }
    }
  }
}
```

Rules: no `export` and no `runtime` (an `export` here is an error); names are lowercase
letters, digits, `-` and `_`, unique, at most 32 commands; a save of the manifest updates the menu.

```sh
cmux ext dev --once --json
```

<!-- recipe-check: loads -->
Exit 0; `placed` says "the agent chat composer's / menu". Type `/st` in a chat to see it.
