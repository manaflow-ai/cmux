// Live check of GitExecMemoryStore on a Freestyle VM.
// Usage: FREESTYLE_API_KEY=… bun scripts/memory-store-check.ts <vm id>
import { compact, wake } from "@mux/brain";
import { GitExecMemoryStore } from "../src/git-memory-store.ts";

const vmId = process.argv[2];
const apiKey = process.env.FREESTYLE_API_KEY;
if (!vmId || !apiKey)
  throw new Error("usage: FREESTYLE_API_KEY=… bun scripts/memory-store-check.ts <vm id>");
const store = new GitExecMemoryStore(apiKey, vmId, `check-${Date.now().toString(36)}`);
const t0 = Date.now();
await store.append([
  "Lawrence's build box is cmux14",
  "it's raining",
  "quote ' and $HOME and `ticks`",
]);
await store.append(Array.from({ length: 13 }, (_, i) => `fact ${i}`));
console.log("length", await store.length());
console.log("read", await store.read(1, 3));
console.log("recall", await store.recall("build box|ticks", 5));
const view = await wake(store, 6);
const written = await compact(
  store,
  view.missing,
  async ({ left, right }) => `${left.slice(0, 20)} + ${right.slice(0, 20)}`,
);
console.log("compacted", written);
console.log((await wake(store, 6)).text);
console.log("ms", Date.now() - t0);
