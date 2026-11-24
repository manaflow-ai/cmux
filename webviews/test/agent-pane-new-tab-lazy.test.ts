import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

// New Tab's screens (NewTabScreen and the classic NewTabPage) load from their own chunk
// (newtab/lazyNewTab.tsx), not from the chat page's first script: a restored chat's first paint
// never draws them. This walks the pane's static import graph from its entry, the set the page
// parses before its first frame, and fails when either screen comes back into it.

const pane = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
const entry = path.join(pane, "main.tsx");
// Static value imports and re-exports: `import type` and `export type` are erased, and import() is a
// chunk. `import { type A }` counts as a value import, which keeps the check strict.
const STATIC = /^\s*(?:import|export)\s+(?!type\b)(?:[^;'"]*?\sfrom\s*)?["']([^"']+)["']/gm;
const EXTENSIONS = ["", ".tsx", ".ts", "/index.tsx", "/index.ts"];

function resolve(from: string, spec: string): string | undefined {
  if (!spec.startsWith(".")) return undefined;
  const base = path.resolve(path.dirname(from), spec);
  for (const ext of EXTENSIONS) {
    const file = base + ext;
    if (/\.(tsx?|jsx?)$/.test(file) && fs.existsSync(file) && fs.statSync(file).isFile()) return file;
  }
  return undefined;
}

function staticGraph(start: string): Set<string> {
  const seen = new Set<string>();
  const stack = [start];
  while (stack.length > 0) {
    const file = stack.pop()!;
    if (seen.has(file)) continue;
    seen.add(file);
    const source = fs.readFileSync(file, "utf8");
    for (const found of source.matchAll(STATIC)) {
      const next = resolve(file, found[1]!);
      if (next) stack.push(next);
    }
  }
  return seen;
}

describe("agent pane first script", () => {
  const graph = staticGraph(entry);

  test("walks the pane", () => {
    expect(graph.has(path.join(pane, "App.tsx"))).toBe(true);
    expect(graph.has(path.join(pane, "newtab/lazyNewTab.tsx"))).toBe(true);
  });

  test("leaves New Tab's screens to their own chunk", () => {
    const eager = ["newtab/NewTabScreen.tsx", "NewTabPage.tsx"].filter((file) => graph.has(path.join(pane, file)));
    expect(eager).toEqual([]);
  });
});
