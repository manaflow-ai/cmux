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

`dist/main.js` is committed, because Settings installs that file: rebuild it with
`bun examples/extensions/build.ts` after you change `src/main.ts`.
