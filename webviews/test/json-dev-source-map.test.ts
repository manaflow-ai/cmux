// A dev server sends a JSON import without vite-plus's fallback source map (dev-server/jsonDevSourceMap.mjs):
// without the plugin the module carries a hires identity map of its whole text, about 6x its size
// (the agent pane's generated/strings.json: 5.3 MB on disk, 26.7 MB served).
import { afterAll, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createServer, type ViteDevServer } from "vite";
import { jsonDevSourceMap } from "../dev-server/jsonDevSourceMap.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "json-dev-map-"));
const table = Object.fromEntries(
  ["en", "de", "pt-BR"].map((code) => [
    code,
    Object.fromEntries(Array.from({ length: 2000 }, (_, i) => [`key.${i}`, `${code} text ${i}`])),
  ]),
);
fs.writeFileSync(path.join(root, "strings.json"), JSON.stringify(table));
const servers: ViteDevServer[] = [];

async function serve(withPlugin: boolean) {
  const server = await createServer({
    configFile: false,
    root,
    logLevel: "silent",
    cacheDir: path.join(root, `.vite-${withPlugin}`),
    server: { host: "127.0.0.1", port: 0 },
    plugins: withPlugin ? [jsonDevSourceMap()] : [],
  });
  servers.push(server);
  await server.listen();
  const address = server.httpServer!.address() as { port: number };
  const response = await fetch(`http://127.0.0.1:${address.port}/strings.json?import`);
  expect(response.status).toBe(200);
  return response.text();
}

afterAll(async () => {
  await Promise.all(servers.map((server) => server.close()));
  fs.rmSync(root, { recursive: true, force: true });
});

test("a JSON import is served without a source map, as its plain module", async () => {
  const before = await serve(false);
  const after = await serve(true);
  expect(after).not.toContain("sourceMappingURL");
  // The module itself is unchanged: only the map is dropped.
  expect(after).toBe(
    before.replace(/\n\/\/# sourceMappingURL=[^\n]*\n?$/, "").trimEnd() + (after.endsWith("\n") ? "\n" : ""),
  );
  expect(after.length).toBeLessThan(fs.statSync(path.join(root, "strings.json")).size * 1.5);
  const mod = await import(`data:text/javascript;base64,${Buffer.from(after).toString("base64")}`);
  expect(mod.default).toEqual(table);
  expect(mod.de["key.7"]).toBe("de text 7");
});
