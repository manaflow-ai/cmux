# cmux TypeScript Client

Node.js client for the cmux-mux Unix-socket JSON-lines protocol.

## Build

```bash
npm i cmux
npm install
npm run build
```

The package has no runtime dependencies. Node 20 or newer is required.

## Usage

```ts
import { CmuxClient } from "cmux";

const client = new CmuxClient({ socketPath: process.env.CMUX_MUX_SOCKET });
const info = await client.identify();
const created = await client.newWorkspace({ name: "sdk-demo", cols: 80, rows: 24 });
await client.send(created.surface, { text: "echo hello\r" });
console.log((await client.readScreen(created.surface)).text);
await client.close();
```

## E2E

```bash
CMUX_MUX_SOCKET=/path/to/session.sock npm run e2e
```
