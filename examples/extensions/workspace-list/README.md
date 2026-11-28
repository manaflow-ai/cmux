# Workspace list: the built-in list, forkable

`local/workspace-list` is cmux's workspace list rebuilt on the public SDK
(`cmux-extension-sdk`), with nothing private. Copy the folder and make the list yours.

- **The whole list** (`cmux.sidebar/1`, `renderSidebar`). cmux draws it in place of the built-in
  list once you opt in. The built-in list is the default and the fallback: cmux draws it while your
  list loads, if its script fails or crashes, if you remove the extension, and in safe mode.
- **The same list as a section** (`cmux.section/1`, `renderSection`), to place in the sidebar
  beside the built-in list from its edit mode.

Each row is one workspace in your order. The one you are in is selected, and the badge counts the
chats in it that wait for you. Click a row to show that workspace. It re-reads when cmux sends
`workspace.changed` and `agent_chat.changed`, and polls nothing.

## Use it

```sh
cd examples/extensions/workspace-list
cmux ext dev            # loads it into the running cmux; every save reloads it
cmux settings set sidebar.workspaceListApp local/workspace-list   # draw it in place of the built-in list
cmux settings set sidebar.workspaceListApp ""                     # back to the built-in list
```

## Fork it

Copy the folder, change `id` in `cmux-app.json` (for example `local/my-list`), and set
`sidebar.workspaceListApp` to that id. Outside this repository, run `npm install` and remove
`paths` from `tsconfig.json`.

## Files

- `cmux-app.json`: the manifest. The Rust SDK's `Manifest` builder makes the same one
  (`cmux-tui/crates/cmux-extension-sdk/tests/sdk.rs`).
- `src/main.ts`: the code.
- Tests: `cmux-tui/crates/cmux-app-host/js/test/examples.test.ts` ("local/workspace-list") mounts
  it in the fake host, including a 500-workspace list.
