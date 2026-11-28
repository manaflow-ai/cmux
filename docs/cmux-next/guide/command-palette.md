# Command palette

Every command in the palette, with its default shortcut and CLI command.

Press Cmd+Shift+P to open the command palette. Type a few letters of a command, then press Return. The palette also finds workspaces, tabs, files, and settings.

Start the query with a scope prefix to search one kind of thing. Set the prefixes in Settings > General (the palette.scopes keys).

```bash
cmux palette open
```

This list is generated from the action catalog, the same catalog the app builds its palette, menus, CLI, and MCP tools from. A test fails when the catalog changes and this page does not.

The full table is generated from the app's own catalog. In a cmux terminal, `cmux action list` print it.
