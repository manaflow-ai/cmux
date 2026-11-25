# Agent pet: a cat whose mood follows your agents

`local/showcase-agent-pet` imports nothing but `cmux-extension-sdk`. A small cat sits in the
sidebar. It naps while nothing runs, watches while agents work, rings when a chat waits for your
answer and worries when one stopped. When a chat needs you, a click on the cat opens it.

- `agents()` and `chats()` re-read when cmux sends `agent.changed` and `agent_chat.changed`, so
  the pet costs nothing while your agents are quiet.
- Its name is a setting (Settings > Apps > Agent pet).

## Run it

```sh
cd examples/extensions/agent-pet
cmux ext dev
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). Outside
this repository, copy the folder and run `npm install` first; inside it, `tsconfig.json` points
the import at the SDK's source. Tests:
`cmux-tui/crates/cmux-app-host/js/test/showcase-examples.test.ts` packs each sample and runs it
in the fake host.
