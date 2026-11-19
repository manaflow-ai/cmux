# Workspace notes: a to-do list per workspace

`local/showcase-workspace-notes` imports nothing but `cmux-extension-sdk`. A sidebar section keeps
a short list for the workspace you are in; switch workspaces and the list switches with you.

- Type a note and press Return to add it. Click a note to tick it; right-click to remove it or
  clear the ticked ones.
- `workspaces()` says which workspace is focused (re-read on `workspace.changed`). Each list is
  kept with `storage:local` under the workspace's id, so it survives a restart.

## Run it

```sh
cd examples/extensions/workspace-notes
cmux ext dev
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). Outside
this repository, copy the folder and run `npm install` first; inside it, `tsconfig.json` points
the import at the SDK's source. Tests:
`cmux-tui/crates/cmux-app-host/js/test/showcase-examples.test.ts` packs each sample and runs it
in the fake host.
