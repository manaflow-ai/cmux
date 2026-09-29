#!/usr/bin/env node
// Budgets the JavaScript the `cmux diff` viewer evaluates on every open.
//
// The diff surface is `main.mjs` -> `chunks/diffSurface.mjs` plus every chunk
// those two reach through static imports. Anything shiki resolves on demand
// (TextMate grammars, themes, the Oniguruma WASM blob) must stay a dynamic
// import so it is fetched only for the languages in the diff. This script
// walks the committed bundle under `Resources/markdown-viewer/webviews-app`,
// sums the eager closure and fails when it grows past the budget or when a
// grammar, theme or WASM chunk is reachable statically.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const bundleDirectory = resolve(process.argv[2] ?? join(repositoryRoot, "Resources/markdown-viewer/webviews-app"));
const budgetBytes = Number(process.env.CMUX_WEBVIEWS_DIFF_EAGER_BUDGET_BYTES ?? 1_500_000);
if (!Number.isSafeInteger(budgetBytes) || budgetBytes <= 0) {
  console.error("CMUX_WEBVIEWS_DIFF_EAGER_BUDGET_BYTES must be a positive integer");
  process.exit(2);
}

const diffSurfaceEntries = ["main.mjs", "chunks/diffSurface.mjs"];
const lazyOnlyChunkPattern = /^chunks\/(shiki-lang-|shiki-theme-|shiki-wasm|pierre-theme-)/;
const staticImportPattern = /(?:^|[;}\s])(?:import|export)\s*(?:[^;'"()]*?from\s*)?["']([^"']+)["']/g;

function staticImports(filePath) {
  const source = readFileSync(filePath, "utf8");
  const specifiers = new Set();
  for (const match of source.matchAll(staticImportPattern)) {
    const specifier = match[1];
    if (specifier.startsWith(".")) {
      specifiers.add(resolve(dirname(filePath), specifier));
    }
  }
  return specifiers;
}

function eagerClosure(entryRelativePaths) {
  const seen = new Map();
  const queue = entryRelativePaths.map((entry) => resolve(bundleDirectory, entry));
  while (queue.length > 0) {
    const filePath = queue.pop();
    if (seen.has(filePath)) {
      continue;
    }
    let size;
    try {
      size = statSync(filePath).size;
    } catch {
      console.error(`missing bundle file: ${relative(bundleDirectory, filePath)}`);
      process.exit(2);
    }
    seen.set(filePath, size);
    for (const dependency of staticImports(filePath)) {
      queue.push(dependency);
    }
  }
  return seen;
}

function listChunks() {
  const chunksDirectory = join(bundleDirectory, "chunks");
  return readdirSync(chunksDirectory).filter((name) => name.endsWith(".mjs")).map((name) => `chunks/${name}`);
}

const eager = eagerClosure(diffSurfaceEntries);
const rows = Array.from(eager, ([filePath, size]) => [relative(bundleDirectory, filePath), size])
  .sort((left, right) => right[1] - left[1]);
const totalBytes = rows.reduce((sum, [, size]) => sum + size, 0);
const failures = [];
for (const [relativePath] of rows) {
  if (lazyOnlyChunkPattern.test(relativePath)) {
    failures.push(`${relativePath} is reachable through static imports; it must stay a dynamic import`);
  }
}
if (totalBytes > budgetBytes) {
  failures.push(`diff surface evaluates ${totalBytes} bytes on open, budget is ${budgetBytes} bytes`);
}

const allChunks = listChunks();
const lazyChunks = allChunks.filter((name) => !eager.has(resolve(bundleDirectory, name)));
console.log(`diff surface eager JS: ${totalBytes} bytes across ${rows.length} files (budget ${budgetBytes})`);
for (const [relativePath, size] of rows) {
  console.log(`  ${String(size).padStart(9)}  ${relativePath}`);
}
console.log(`lazy chunks: ${lazyChunks.length}`);
if (failures.length > 0) {
  for (const failure of failures) {
    console.error(`error: ${failure}`);
  }
  process.exit(1);
}
