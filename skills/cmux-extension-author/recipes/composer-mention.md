# Recipe: an @ mention provider in the agent chat composer

Items a person names with `@` in the composer; `@ticket:` narrows the menu to them.
Interface: `cmux.composer.mention/1`
([contract](../../../cmux-tui/crates/cmux-app-host/interfaces/cmux.composer.mention/1.json)).
The daemon ranks the items in Rust from the manifest; there is no script.

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-composer-mention",
  "name": "Tickets",
  "version": "0.1.0",
  "description": "Mention a ticket in the agent chat.",
  "engines": { "cmux": "^2.0" },
  "implements": {
    "cmux.composer.mention/1": {
      "options": {
        "prefix": "ticket",
        "items": [
          { "id": "ENG-1", "label": "ENG-1 Login fails on Safari", "insert": "ENG-1" },
          { "id": "ENG-2", "label": "ENG-2 Slow sidebar", "detail": "In progress" }
        ]
      }
    }
  }
}
```

Rules: `prefix` is a lowercase word (at most 24 characters); each item needs `id` and
`label`; `insert` defaults to the label; at most 200 items.

```sh
cmux ext dev --once --json
```

<!-- recipe-check: loads -->
Exit 0; `placed` says "the agent chat composer's @ completions". Type `@ticket:` in a chat.
