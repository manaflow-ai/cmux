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

`dist/main.js` is committed, because Settings installs that file: rebuild it with
`bun examples/extensions/build.ts` after you change `src/main.ts`.
