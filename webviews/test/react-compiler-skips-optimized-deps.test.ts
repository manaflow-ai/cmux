// The React Compiler's Babel pass is for first-party sources. scripts/ci/run-webviews-tests.sh gives
// each dev-server test file its own Vite cache (CMUX_VITE_CACHE_DIR, /tmp/.../vite/N), outside
// node_modules, and the pass skipped only node_modules: every optimized dependency (react-dom,
// monaco, shiki, each several MB) went through Babel and the compiler again in each file. The gallery
// browser files spent their 120 s on that and timed out in react-apps-check with every test passing.
// This resolves the gallery dev config the way the runner does and asks the pass's own filter.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const webviews = path.resolve(import.meta.dir, "..");

// A child process: viteCacheDir is read once, when its module loads.
const PROBE = `
import path from "node:path";
const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(process.cwd(), "vite.config.gallery-dev.ts"),
  server: { middlewareMode: true, watch: { ignored: () => true } },
  logLevel: "error",
});
const babel = vite.config.plugins.find((plugin) => plugin.name === "@rolldown/plugin-babel");
const filter = babel?.transform?.filter?.id ?? {};
const matches = (patterns, id) => [patterns ?? []].flat().some((pattern) => pattern.test(id));
const compiles = (id) => matches(filter.include, id) && !matches(filter.exclude, id);
const cache = vite.config.cacheDir;
console.log(JSON.stringify({
  found: Boolean(babel),
  cache,
  source: compiles(path.join(process.cwd(), "src/agent-session/acpmux/App.tsx")),
  dep: compiles(path.join(cache, "deps/react-dom_client.js") + "?v=153aa9e6"),
  ssrDep: compiles(path.join(cache, "deps_ssr/react-dom_server.js")),
  defaultDep: compiles(path.join(process.cwd(), "node_modules/.vite/deps/react-dom_client.js") + "?v=153aa9e6"),
}));
await vite.close();
`;

function probe(cacheDir: string | undefined) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "react-compiler-deps-"));
  const script = path.join(dir, "probe.mjs");
  fs.writeFileSync(script, PROBE);
  const env = { ...process.env };
  if (cacheDir) env.CMUX_VITE_CACHE_DIR = cacheDir;
  else delete env.CMUX_VITE_CACHE_DIR;
  const result = Bun.spawnSync(["bun", script], { cwd: webviews, env, stdout: "pipe", stderr: "pipe" });
  fs.rmSync(dir, { recursive: true, force: true });
  const out = result.stdout.toString().trim().split("\n").at(-1) ?? "";
  if (result.exitCode !== 0 || !out.startsWith("{"))
    throw new Error(`probe failed (${result.exitCode}): ${result.stderr.toString()}\n${out}`);
  return JSON.parse(out) as {
    found: boolean;
    cache: string;
    source: boolean;
    dep: boolean;
    ssrDep: boolean;
    defaultDep: boolean;
  };
}

describe("the React Compiler pass", () => {
  test("skips the optimized dependencies in a per-file Vite cache, as the CI runner sets it", () => {
    const cache = fs.mkdtempSync(path.join(os.tmpdir(), "vite-cache-"));
    try {
      const seen = probe(path.join(cache, "vite", "20"));
      expect(seen.found).toBe(true);
      expect(seen.cache).toBe(path.join(cache, "vite", "20"));
      expect(seen.source).toBe(true);
      expect(seen.dep).toBe(false);
      expect(seen.ssrDep).toBe(false);
    } finally {
      fs.rmSync(cache, { recursive: true, force: true });
    }
  }, 60_000);

  test("skips them in Vite's default cache too", () => {
    const seen = probe(undefined);
    expect(seen.source).toBe(true);
    expect(seen.defaultDep).toBe(false);
  }, 60_000);
});
