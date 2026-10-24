import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";

// The editor's find pill is only needed after Cmd-F. Keep it out of the editor page's first-load
// closure so opening a file does not pay for a control that is not visible yet.
const bundleDirectory = resolve(import.meta.dir, "../../Resources/markdown-viewer/webviews-app");
const editorEntry = resolve(bundleDirectory, "chunks/editor-page.mjs");
const diffEntries = [resolve(bundleDirectory, "main.mjs"), resolve(bundleDirectory, "chunks/diffSurface.mjs")];
const staticImportPattern = /(?:^|[;}\s])(?:import|export)\s*(?:[^;'"()]*?from\s*)?["']([^"']+)["']/g;

function eagerClosure(entry: string): string[] {
  const seen = new Set<string>();
  const queue = [entry];
  while (queue.length > 0) {
    const filePath = queue.pop()!;
    if (seen.has(filePath)) continue;
    seen.add(filePath);
    const source = readFileSync(filePath, "utf8");
    for (const match of source.matchAll(staticImportPattern)) {
      if (match[1].startsWith(".")) queue.push(resolve(dirname(filePath), match[1]));
    }
  }
  return Array.from(seen, (filePath) => basename(filePath));
}

test("the editor keeps its find pill out of the first-load closure", () => {
  expect(existsSync(editorEntry)).toBe(true);
  expect(eagerClosure(editorEntry)).not.toContain("FindPill.mjs");
});

test("the diff viewer keeps its find pill out of the first-load closure", () => {
  for (const entry of diffEntries) expect(existsSync(entry)).toBe(true);
  for (const entry of diffEntries) expect(eagerClosure(entry)).not.toContain("FindPill.mjs");
});
