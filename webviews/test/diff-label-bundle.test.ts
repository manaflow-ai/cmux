import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const bundle = resolve(import.meta.dir, "../../Resources/markdown-viewer/webviews-app");
const staticImports = /(?:^|[;}\s])(?:import|export)\s*(?:[^;'"()]*?from\s*)?["']([^"']+)["']/g;

function eagerSources(entry: string): string[] {
  const seen = new Set<string>();
  const queue = [resolve(bundle, entry)];
  const sources: string[] = [];
  while (queue.length) {
    const file = queue.pop()!;
    if (seen.has(file)) continue;
    seen.add(file);
    const source = readFileSync(file, "utf8");
    sources.push(source);
    for (const match of source.matchAll(staticImports))
      if (match[1]!.startsWith(".")) queue.push(resolve(dirname(file), match[1]!));
  }
  return sources;
}

test("the built diff entry and its eager dependencies contain no translated diff labels", () => {
  const source = eagerSources("chunks/diffSurface.mjs").join("\n");
  expect(source.includes("Dateien ausblenden")).toBe(false);
  expect(source.includes("ファイルを隠す")).toBe(false);
});

test("the selected Japanese locale chunk contains no German diff labels", () => {
  const source = eagerSources("chunks/diff-labels-ja.mjs").join("\n");
  expect(source.includes("ファイルを隠す")).toBe(true);
  expect(source.includes("Dateien ausblenden")).toBe(false);
});
