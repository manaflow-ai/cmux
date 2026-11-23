# Standup: what your agents did since yesterday

`local/showcase-agent-standup` imports nothing but `cmux-extension-sdk`. A sidebar section sums up
the last day (chats finished, still working, waiting for you), then lists each project with the
chats that changed in it, newest first. A click opens a chat.

- `chats()` re-reads when cmux sends `agent_chat.changed`; one timer every five minutes keeps the
  "2 h ago" labels current.
- How far back it looks is a setting (Settings > Apps > Standup, default 24 hours).

## Run it

```sh
cd examples/extensions/agent-standup
cmux ext dev
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). Outside
this repository, copy the folder and run `npm install` first; inside it, `tsconfig.json` points
the import at the SDK's source. Tests:
`cmux-tui/crates/cmux-app-host/js/test/showcase-examples.test.ts` packs each sample and runs it
in the fake host.
