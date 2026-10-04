#!/usr/bin/env node
// Budgets the JavaScript the `cmux diff` viewer evaluates on every open, and the first load of the
// diff, markdown and code editor pages (Monaco must stay lazy everywhere).
//
// The diff surface is `main.mjs` -> `chunks/diffSurface.mjs` plus every chunk
// those two reach through static imports. The highlight worker entry
// `chunks/diff-worker.mjs` is evaluated once per pool worker (3 on desktop)
// and gets its own, smaller budget. Anything shiki resolves on demand
// (TextMate grammars, themes, the Oniguruma WASM blob) must stay a dynamic
// import so it is fetched only for the languages in the diff, and the worker
// must never evaluate the main-thread renderer or React. The agent session
// (`main.mjs` -> `chunks/agentSessionSurface.mjs`) shares `vendor` with the
// diff surface but must never load the diff renderer or shiki at startup.
// This script walks
// the committed bundle under `Resources/markdown-viewer/webviews-app`, sums
// each eager closure and fails when one grows past its budget or when a
// forbidden chunk is reachable statically.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const bundleDirectory = resolve(process.argv[2] ?? join(repositoryRoot, "Resources/markdown-viewer/webviews-app"));
function budgetFromEnvironment(name, fallback) {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value <= 0) {
    console.error(`${name} must be a positive integer`);
    process.exit(2);
  }
  return value;
}

const lazyOnlyChunkPattern = /^chunks\/(shiki-lang-|shiki-theme-|shiki-wasm|pierre-theme-|monaco-lang-|monaco-nls-)/;
// Monaco (the code editor page's `view` chunk and its worker) loads only after the editor opens a
// file; no page reaches it through static imports, the editor page's own entry included.
const monacoChunks = ["chunks/view.mjs", "chunks/editor-worker.mjs", "chunks/editorWorkerHost.mjs"];
const surfaces = [
  {
    name: "diff surface",
    entries: ["main.mjs", "chunks/diffSurface.mjs"],
    budgetBytes: budgetFromEnvironment("CMUX_WEBVIEWS_DIFF_EAGER_BUDGET_BYTES", 1_500_000),
    forbidden: [],
  },
  {
    name: "diff worker",
    entries: ["chunks/diff-worker.mjs"],
    budgetBytes: budgetFromEnvironment("CMUX_WEBVIEWS_DIFF_WORKER_EAGER_BUDGET_BYTES", 400_000),
    forbidden: ["chunks/diff-vendor.mjs", "chunks/vendor.mjs"],
  },
  {
    name: "agent session",
    entries: ["main.mjs", "chunks/agentSessionSurface.mjs"],
    budgetBytes: budgetFromEnvironment("CMUX_WEBVIEWS_AGENT_SESSION_EAGER_BUDGET_BYTES", 800_000),
    forbidden: ["chunks/diff-vendor.mjs", "chunks/shiki-core.mjs", ...monacoChunks],
  },
  {
    name: "diff page",
    entries: ["chunks/diff-page.mjs", "chunks/diffSurface.mjs"],
    budgetBytes: budgetFromEnvironment("CMUX_WEBVIEWS_DIFF_PAGE_EAGER_BUDGET_BYTES", 1_500_000),
    forbidden: monacoChunks,
  },
  {
    name: "markdown page",
    entries: ["chunks/markdown-page.mjs"],
    budgetBytes: budgetFromEnvironment("CMUX_WEBVIEWS_MARKDOWN_PAGE_EAGER_BUDGET_BYTES", 1_200_000),
    forbidden: monacoChunks,
  },
  {
    name: "editor page",
    entries: ["chunks/editor-page.mjs"],
    budgetBytes: budgetFromEnvironment("CMUX_WEBVIEWS_EDITOR_PAGE_EAGER_BUDGET_BYTES", 500_000),
    forbidden: monacoChunks,
  },
];
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

const failures = [];
const eagerFiles = new Set();
for (const surface of surfaces) {
  const eager = eagerClosure(surface.entries);
  const rows = Array.from(eager, ([filePath, size]) => [relative(bundleDirectory, filePath), size])
    .sort((left, right) => right[1] - left[1]);
  const totalBytes = rows.reduce((sum, [, size]) => sum + size, 0);
  for (const [relativePath] of rows) {
    eagerFiles.add(relativePath);
    if (lazyOnlyChunkPattern.test(relativePath)) {
      failures.push(`${surface.name}: ${relativePath} is reachable through static imports; it must stay a dynamic import`);
    }
    if (surface.forbidden.includes(relativePath)) {
      failures.push(`${surface.name}: ${relativePath} is reachable through static imports but must stay out of its eager set`);
    }
  }
  if (totalBytes > surface.budgetBytes) {
    failures.push(`${surface.name} evaluates ${totalBytes} bytes on open, budget is ${surface.budgetBytes} bytes`);
  }
  console.log(`${surface.name} eager JS: ${totalBytes} bytes across ${rows.length} files (budget ${surface.budgetBytes})`);
  for (const [relativePath, size] of rows) {
    console.log(`  ${String(size).padStart(9)}  ${relativePath}`);
  }
}

const lazyChunks = listChunks().filter((name) => !eagerFiles.has(name));
console.log(`lazy chunks: ${lazyChunks.length}`);
if (failures.length > 0) {
  for (const failure of failures) {
    console.error(`error: ${failure}`);
  }
  process.exit(1);
}
