#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(fileURLToPath(new URL("..", import.meta.url)));
const appDir = join(root, "Resources", "markdown-viewer", "webviews-app");

// The webviews bundle is code-split, so React Compiler output lands in the
// per-surface chunks (`chunks/*.mjs`) rather than the slim `main.mjs` entry.
// Scan the entry plus every emitted chunk and sum the cache sites.
const chunksDir = join(appDir, "chunks");
const bundlePaths = [join(appDir, "main.mjs")];
if (existsSync(chunksDir)) {
  for (const name of readdirSync(chunksDir)) {
    if (name.endsWith(".mjs")) {
      bundlePaths.push(join(chunksDir, name));
    }
  }
}

let compilerCacheCalls = 0;
for (const bundlePath of bundlePaths) {
  const bundle = readFileSync(bundlePath, "utf8");
  // Each compiled component checks its memo cache against React's sentinel. The cache call itself
  // (`_c(6)`) is a plain imported binding now that React is the one shared module
  // (webviews/scripts/shared/shared-react.mjs), so it has no name to find; the sentinel does.
  compilerCacheCalls += (bundle.match(/react\.memo_cache_sentinel/g) ?? []).length;
}

if (compilerCacheCalls < 8) {
  console.error("React Compiler cache calls were not found in the generated webviews bundle.");
  process.exit(1);
}

console.log(
  `React Compiler enabled for webviews (${compilerCacheCalls} cache sites across ${bundlePaths.length} files).`,
);
