import { expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";

// The highlight worker is built by the same Rollup graph as `main.mjs`, so it
// shares the eager `shiki-core` chunk and the lazy `shiki-wasm` chunk with the
// main thread instead of carrying a vendored copy of shiki. These tests read
// the built bundle under `Resources/markdown-viewer/webviews-app` (scripts/cmux-next/build-web-bundles.sh).
const bundleDirectory = resolve(import.meta.dir, "../../Resources/markdown-viewer/webviews-app");
const chunksDirectory = resolve(bundleDirectory, "chunks");
const workerEntry = resolve(chunksDirectory, "diff-worker.mjs");
const lazyOnlyChunkPattern = /^(shiki-lang-|shiki-theme-|shiki-wasm|pierre-theme-)/;
const staticImportPattern = /(?:^|[;}\s])(?:import|export)\s*(?:[^;'"()]*?from\s*)?["']([^"']+)["']/g;

function staticImports(filePath: string): string[] {
  const source = readFileSync(filePath, "utf8");
  const specifiers: string[] = [];
  for (const match of source.matchAll(staticImportPattern)) {
    if (match[1].startsWith(".")) {
      specifiers.push(resolve(dirname(filePath), match[1]));
    }
  }
  return specifiers;
}

function eagerClosure(entry: string): string[] {
  const seen = new Set<string>();
  const queue = [entry];
  while (queue.length > 0) {
    const filePath = queue.pop()!;
    if (seen.has(filePath)) continue;
    seen.add(filePath);
    queue.push(...staticImports(filePath));
  }
  return Array.from(seen, (filePath) => basename(filePath)).sort();
}

test("the highlight worker is emitted as a Vite entry next to the other chunks", () => {
  expect(existsSync(workerEntry)).toBe(true);
  const chunkNames = readdirSync(chunksDirectory).filter((name) => name.endsWith(".mjs"));
  const spawningChunks = chunkNames.filter((name) =>
    /new URL\((["'`])\.\/diff-worker\.mjs\1,import\.meta\.url\)/.test(
      readFileSync(resolve(chunksDirectory, name), "utf8"),
    ),
  );
  // Only the diff surface spawns workers, and it resolves the entry as a
  // sibling of its own chunk, so `import.meta.url` must live under `chunks/`.
  expect(spawningChunks).toEqual(["diffSurface.mjs"]);
});

test("the worker entry shares shiki with the main thread and stays lazy for grammars and WASM", () => {
  const closure = eagerClosure(workerEntry);
  expect(closure).toContain("shiki-core.mjs");
  expect(eagerClosure(resolve(chunksDirectory, "diffSurface.mjs"))).toContain("shiki-core.mjs");
  for (const name of closure) {
    expect(name).not.toMatch(lazyOnlyChunkPattern);
  }
  // The worker must not evaluate the main-thread renderer or React.
  expect(closure).not.toContain("diff-vendor.mjs");
  expect(closure).not.toContain("vendor.mjs");
  expect(readFileSync(workerEntry, "utf8")).toMatch(/import\((["'`])\.\/shiki-wasm\.mjs\1\)/);
});

test("no vendored worker copy remains in Resources", () => {
  expect(existsSync(resolve(import.meta.dir, "../../Resources/markdown-viewer/diff-viewer"))).toBe(false);
});
