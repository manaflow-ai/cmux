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
  compilerCacheCalls += (bundle.match(/\b[A-Za-z_$][\w$]*\.c\(\d+\)/g) ?? []).length;
}

if (compilerCacheCalls < 8) {
  console.error("React Compiler cache calls were not found in the generated webviews bundle.");
  process.exit(1);
}

console.log(
  `React Compiler enabled for webviews (${compilerCacheCalls} cache sites across ${bundlePaths.length} files).`,
);
