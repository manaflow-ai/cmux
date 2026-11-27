// A save's module is transformed when the watcher sees it, before the page asks, and only once:
// the page's own `?t=` request joins that transform (dev-server/transformOnChange.ts).
import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createServer, type Plugin } from "vite-plus";
import { transformOnChange } from "../dev-server/transformOnChange";

const scratch = mkdtempSync(path.join(tmpdir(), "cmux-transform-on-change-"));
afterAll(() => rmSync(scratch, { recursive: true, force: true }));

test("a saved module is transformed once, before the page's request", async () => {
  const leaf = path.join(scratch, "leaf.js");
  writeFileSync(path.join(scratch, "main.js"), `import { v } from "./leaf.js";\nconsole.log(v);\n`);
  writeFileSync(leaf, `export const v = "before";\nif (import.meta.hot) import.meta.hot.accept();\n`);
  const transforms: string[] = [];
  const counter: Plugin = {
    name: "count-leaf-transforms",
    transform(code, id) {
      if (id === leaf) transforms.push(code);
    },
  };
  const server = await createServer({
    root: scratch,
    configFile: false,
    logLevel: "silent",
    cacheDir: path.join(scratch, ".vite"),
    optimizeDeps: { noDiscovery: true, include: [] },
    server: { middlewareMode: true, hmr: false, watch: null, ws: false },
    plugins: [transformOnChange(), counter],
  });
  try {
    const client = server.environments.client;
    await client.transformRequest("/main.js");
    await client.transformRequest("/leaf.js");
    expect(transforms).toHaveLength(1);

    writeFileSync(leaf, `export const v = "after";\nif (import.meta.hot) import.meta.hot.accept();\n`);
    // What the watcher's change handler does: invalidate, then run the hot-update hooks.
    await client.moduleGraph.onFileChange(leaf);
    const mods = [...(client.moduleGraph.getModulesByFile(leaf) ?? [])];
    const plugin = transformOnChange();
    const hook = plugin.hotUpdate as { handler: (this: unknown, options: unknown) => void };
    hook.handler.call(
      { environment: client },
      { type: "update", file: leaf, modules: mods, timestamp: Date.now(), server },
    );
    // Started before the page asked: in Vite's pending requests, under the URL without `?t=`.
    const pending = (client as unknown as { _pendingRequests: Map<string, unknown> })._pendingRequests;
    expect(pending.has("/leaf.js")).toBe(true);

    // What Vite's updateModules does next, then the page's fetch.
    for (const mod of mods) client.moduleGraph.invalidateModule(mod, new Set(), Date.now(), true);
    const result = await client.transformRequest(`/leaf.js?t=${Date.now()}`);
    expect(result?.code).toContain('"after"');
    // One transform for the save: the page's request joined the early one.
    expect(transforms).toHaveLength(2);
    expect(transforms[1]).toContain('"after"');
  } finally {
    await server.close();
  }
}, 60_000);
