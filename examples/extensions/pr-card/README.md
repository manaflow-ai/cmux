# PR card: a chat widget built only on the public SDK

cmux ships no chat widgets of its own. Widgets are extensions anyone can write and install, and
this folder is one. It is not bundled into the app.

`local/pr-card` imports nothing but `cmux-extension-sdk`:

- **A card under an agent's tool call.** `cmux.chat.widget/1` (`renderCard`) lists the GitHub
  tools it answers in `options.tools`. When an agent calls one (`mcp__github__get_pull_request`),
  cmux's daemon routes the call to this extension and draws the card under it. The card reads
  `{owner, repo, pullNumber}` from the call's input and shows the pull request's state and its
  checks, failures first, five a page. A widget part an agent sends (`{type: "widget", app:
  "local/pr-card", props: {repo, number}, fallback}`) draws the same card.
- **A sidebar section.** `cmux.section/1` (`renderSection`) lists the pull requests the cards
  showed, newest first.
- **State that outlives the card.** The page of checks is kept in `cmux.storage` under the
  widget's key, so it survives scrolling away, a reload and a relaunch.

## Run it

```sh
cd examples/extensions/pr-card
cmux ext dev            # loads it into the running cmux; every save reloads it
```

The first run asks you to install it. Then ask an agent with the GitHub MCP server to read a pull
request. Edit `src/main.ts` and save: the card redraws in place, with no restart.

Outside this repository, copy the folder, run `npm install` (the dependency is
`cmux-extension-sdk`) and remove `paths` from `tsconfig.json`.

## Files

- `cmux-app.json`: the manifest. The Rust SDK's `Manifest::chat_widget` makes the same widget
  entry (`cmux-tui/crates/cmux-extension-sdk/tests/sdk.rs`).
- `src/main.ts`: the code. `cmux ext dev` builds `dist/main.js` from it.
- Tests: `cmux-tui/crates/cmux-app-host/js/test/examples.test.ts` ("local/pr-card") mounts the card
  in the fake host with a tool call's context.
