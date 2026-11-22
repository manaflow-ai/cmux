// Fills one Vite config's dependency cache (CMUX_VITE_CACHE_DIR) without running a test file, for
// scripts/ci/run-webviews-tests.sh. Run from webviews/:
//   CMUX_VITE_CACHE_DIR=DIR bun scripts/warm-vite-dep-cache.mjs CONFIG_FILE
// It starts the config's dev server with no listener, waits for the dependency optimizer's first scan
// and for its bundle to be committed (DIR/deps/_metadata.json), then closes the server. Exit 0 means
// DIR holds a finished cache that each dev server file can copy; any other exit leaves the runner to
// warm the config with a test file, as before.
//
// Before this, the runner warmed each config by running one of its test files alone, and in 15 shard
// logs (2026-11-21/22) that warming was a red whole-gallery sweep: control-contrast-N (about 610 s) and
// then accent-glass-invariants-N (about 460 s) ran one at a time on a 16 vCPU runner, 32% of the
// shards' test time, because a sweep reads the built gallery and never fills the dev server's cache.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";

const cacheDir = process.env.CMUX_VITE_CACHE_DIR;
const configFile = process.argv[2];
if (!cacheDir || !configFile) {
  console.error("usage: CMUX_VITE_CACHE_DIR=DIR bun scripts/warm-vite-dep-cache.mjs CONFIG_FILE");
  process.exit(2);
}
const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const metadata = path.join(cacheDir, "deps", "_metadata.json");
const limitMs = Number(process.env.CMUX_VITE_DEP_WARM_MS) || 240_000;
const started = performance.now();
const server = await createServer({
  configFile: path.resolve(webviews, configFile),
  server: { middlewareMode: true, hmr: false, ws: false, watch: { ignored: () => true } },
  logLevel: "error",
});
let ok = false;
try {
  const optimizer = server.environments?.client?.depsOptimizer;
  await optimizer?.scanProcessing;
  // With no request to wait for, the optimizer ends its crawl on its own and commits the scan's bundle:
  // it writes deps_temp_* and renames it to deps/ once whole, so _metadata.json is a finished cache.
  while (performance.now() - started < limitMs) {
    if (fs.existsSync(metadata) && fs.statSync(metadata).size > 0) {
      ok = true;
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
} finally {
  await server.close();
}
const seconds = Math.round((performance.now() - started) / 1000);
if (!ok) {
  console.error(`warm-vite-dep-cache: ${configFile} committed no dependency cache in ${seconds} s`);
  process.exit(1);
}
const optimized = Object.keys(JSON.parse(fs.readFileSync(metadata, "utf8")).optimized ?? {}).length;
console.log(`warm-vite-dep-cache: ${configFile}: ${optimized} dependencies in ${seconds} s`);
