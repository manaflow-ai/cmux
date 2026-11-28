import path from "node:path";
import { createServer } from "vite";
const vite = await createServer({ configFile: path.resolve("vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
await vite.listen();
const port = (vite.httpServer!.address() as { port: number }).port;
const r = await fetch(`http://127.0.0.1:${port}/gallery/src/agent-session/acpmux/conversation/BlankLoadFade.gallery.tsx`);
console.log(r.status); console.log((await r.text()).slice(0, 1500));
await vite.close();
