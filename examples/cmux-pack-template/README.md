# cmux Pack Template

Prototype pack for sharing cmux actions, commands, and UI defaults.

Fork or clone a pack into the project, then load it from a project config:

```json
{
  "packs": ["./packs/team-defaults"]
}
```

cmux resolves a directory pack to `cmux.pack.json`, so the example above loads `./packs/team-defaults/cmux.pack.json`.

Pack entries use the `cmux.json` action, command, and UI-default syntax. Project configs override pack entries with the same action id or command name. Pack paths are local files or directories only.
