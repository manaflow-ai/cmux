// The diff page's highlight worker loads in every dev server that draws a diff. worker-pool.ts spawns
// `./diff-worker.mjs` beside itself, a file only the build emits; in dev it is the TypeScript entry.
// The live gallery (`bun run gallery:dev`) left out the dev server's rewrite, so its workers 404ed and
// every pages.diff state drew bare black file bars.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";

setDefaultTimeout(120_000);
const webviews = path.resolve(import.meta.dir, "..");
const servers: { close(): Promise<void> }[] = [];
afterAll(async () => {
  for (const server of servers) await server.close();
});

async function workerResponse(base: string, config: Record<string, unknown>) {
  const { createServer } = await import("vite");
  const vite = await createServer({
    root: webviews,
    ...config,
    server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
    logLevel: "error",
  });
  servers.push(vite);
  await vite.listen();
  const { port } = vite.httpServer!.address() as { port: number };
  const response = await fetch(`http://127.0.0.1:${port}${base}src/diff-worker.mjs`);
  return { status: response.status, type: response.headers.get("content-type") ?? "", body: await response.text() };
}

test("the live gallery serves the diff worker", async () => {
  const worker = await workerResponse("/gallery/", { configFile: path.join(webviews, "vite.config.gallery-dev.ts") });
  expect(worker.status).toBe(200);
  expect(worker.type).toContain("javascript");
  expect(worker.body).toContain("diffs_worker");
});

// One config file per process: a second bundled config races Vite's temp file, so the dev
// server's half is its plugin list plus the plugin on its own at the root base.
test("the dev server serves the diff worker too", async () => {
  const { cmuxDevServer, diffWorkerEntry } = await import("../dev-server/plugins");
  expect(cmuxDevServer().map((plugin) => plugin.name)).toContain(diffWorkerEntry().name);
  const worker = await workerResponse("/", { configFile: false, plugins: [diffWorkerEntry()] });
  expect(worker.status).toBe(200);
  expect(worker.type).toContain("javascript");
});
