# Replace the workspace list: `cmux.sidebar/1`

An extension can draw the whole workspace list in place of the built-in one. You opt in; nothing
changes until you do.

- The interface: [`cmux-app-host/interfaces/cmux.sidebar/1.json`](../../../cmux-tui/crates/cmux-app-host/interfaces/cmux.sidebar/1.json)
- The SDK helper: `sidebar(render)` in `cmux-extension-sdk` (TypeScript), `Manifest::sidebar` (Rust)
- The example to copy: [`examples/extensions/workspace-list`](../../../examples/extensions/workspace-list),
  the built-in workspace list rebuilt on the public SDK. It also implements `cmux.section/1`, so the
  same list can be placed as a section beside the built-in one.
- The setting: `sidebar.workspaceListApp`, the id of the installed extension (empty by default).

## Opt in, and back out

```sh
cd examples/extensions/workspace-list && cmux ext dev      # install it; every save reloads it
cmux settings set sidebar.workspaceListApp local/workspace-list
cmux settings set sidebar.workspaceListApp ""               # the built-in list again
```

The setting is also in Settings > Appearance > Sidebar ("Workspace List Extension"), the command
palette and the MCP `settings_set` tool.

## The built-in list is the fallback

The sidebar draws its own list, unchanged, whenever the extension's list is not drawn:

- no extension is named, or the named app is not installed, is hidden or disabled;
- it has no `cmux.sidebar/1` implementation;
- its first scene has not arrived yet (no blank list while it loads);
- its script fails to load or crashes (the next good save brings it back);
- apps cannot run here: no app host, apps turned off, or safe mode ([safe-mode.md](safe-mode.md)).

The sidebar's own pieces (the bands above and below the list, the footer, the cards) stay native.
The list frame is the only thing the extension draws, so a broken extension can never take away
the way to reach a workspace (DESIGN R5).

## Fork the built-in list

Copy `examples/extensions/workspace-list`, change its `id` (for example `local/my-list`), edit
`src/main.ts`, and name your id in `sidebar.workspaceListApp`. `cmux ext dev` reloads it on every
save. Its test (`cmux-app-host/js/test/examples.test.ts`, "local/workspace-list") shows how to drive
it in the fake host, including a 500-workspace list.
