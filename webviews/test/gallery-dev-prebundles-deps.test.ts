// The gallery dev server (vite.config.gallery-dev.ts) pre-bundles every dependency the gallery's
// stages import in its first scan. It mounts each stage's entry through a virtual module that Vite's
// scanner cannot follow, so the first scan found only what the gallery shell imports, and a stage
// that imported another dependency (a Base UI part, TanStack Virtual) re-optimized mid-run: the
// shared chunks were renamed under the open page ("The file does not exist at .../deps/
// with-selector-CmGIwqRk.js"), and accent-glass-invariants-3 lost its browser and timed out (run
// 41942282745). This starts the gallery's server on a fresh cache, as the CI runner's warming file
// does, and reads what the first scan found.
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
const optimizer = vite.environments.client.depsOptimizer;
await optimizer?.scanProcessing;
const metadata = optimizer?.metadata;
console.log(JSON.stringify([...Object.keys(metadata?.optimized ?? {}), ...Object.keys(metadata?.discovered ?? {})]));
await vite.close();
`;

function firstScan(): string[] {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gallery-dev-deps-"));
  const script = path.join(webviews, `.gallery-dev-deps-probe-${process.pid}.mjs`);
  fs.writeFileSync(script, PROBE);
  try {
    const result = Bun.spawnSync(["bun", script], {
      cwd: webviews,
      env: { ...process.env, CMUX_VITE_CACHE_DIR: path.join(dir, "vite", "seed-gallery-1") },
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = result.stdout.toString().trim().split("\n").at(-1) ?? "";
    if (result.exitCode !== 0 || !out.startsWith("["))
      throw new Error(`probe failed (${result.exitCode}): ${result.stderr.toString()}\n${out}`);
    return JSON.parse(out) as string[];
  } finally {
    fs.rmSync(script, { force: true });
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

describe("the gallery dev server", () => {
  test("pre-bundles the dependencies its stages import in its first scan", () => {
    const found = new Set(firstScan());
    // Each imported only below a stage's entry, never by the gallery shell itself.
    for (const dependency of [
      "@base-ui/react/dialog",
      "@base-ui/react/tabs",
      "@tanstack/react-virtual",
      "@tanstack/react-query",
      "@chenglou/pretext",
    ])
      expect(found.has(dependency), `${dependency} was not in the first scan`).toBe(true);
  }, 300_000);
});
