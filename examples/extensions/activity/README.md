# Activity: an extension built only on the public SDK

`local/activity` imports nothing but `cmux-extension-sdk`. It shows the three things most
extensions need:

- **It changes the sidebar.** A section (`cmux.section/1`, `renderSection`) lists each workspace
  with the chats in it that wait for you, and how many agents are working. Click a row to show
  that workspace.
- **It adds a pane.** `cmux.pane/1` (`renderPane`) is a live feed of the workspace, agent and
  chat events cmux sends.
- **It reacts to events.** `workspaces()`, `agents()` and `chats()` re-read when cmux sends
  `workspace.changed`, `agent.changed` and `agent_chat.changed`; `on(stream, fn)` feeds the pane.
  Nothing polls, and closing the pane unsubscribes.

## Run it

```sh
cd examples/extensions/activity
cmux ext dev            # loads it into the running cmux; every save reloads it
```

The first run asks you to install it (a card in cmux). Then place the section from the sidebar's
edit mode and open the pane from the command palette ("Activity feed"). Edit `src/main.ts` and
save: cmux redraws the section in place, and `ext dev` prints `reloaded in N ms`.

Outside this repository, copy the folder, run `npm install` (the dependency is
`cmux-extension-sdk`) and remove `paths` from `tsconfig.json`; in this repository `paths` points
the import at the SDK's source so the folder builds with no install.

## Files

- `cmux-app.json`: the manifest. The Rust SDK's `Manifest` builder makes the same one
  (`cmux-tui/crates/cmux-extension-sdk/tests/sdk.rs`).
- `src/main.ts`: the code. `dist/main.js` is built from it by `cmux ext dev` (or
  `bun cmux-tui/crates/cmux-app-host/tools/pack.ts examples/extensions/activity`).
- Tests: `cmux-tui/crates/cmux-app-host/js/test/examples.test.ts` ("local/activity") mounts it in
  the fake host and drives its events.
