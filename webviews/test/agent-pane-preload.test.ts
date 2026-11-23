// The agent pane's first chat paint waits for pane.js, so the page is built for V8 to serve it from its code
// cache: pane.js is one classic script holding the entry and every chunk it imports statically
// (bundle.mjs --classic). V8 writes an ES module's code cache on every load and never reads it (Chrome 158: a
// warm load compiled 4,387 functions, as a cold one did, first contentful paint 417 ms), and serves a classic
// script's (23 functions, 232 ms): scripts/measure/pane-compile-ab.mjs. The chunks left are ES modules that
// `import()` loads when used, so nothing is preloaded but pane.js.
//
// The page is the built resource (CI builds the web bundles before this suite; locally run
// scripts/cmux-next/build-agent-pane-web.sh first).
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const dir = path.resolve(
  import.meta.dir,
  "../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
);
const page = path.join(dir, "index.html");
const built = fs.existsSync(page);
if (!built && process.env.CI) throw new Error(`agent-pane-preload: ${page} is not built`);
if (!built) console.warn("agent-pane-preload: skipping (run scripts/cmux-next/build-agent-pane-web.sh)");

/** Files `file` imports with a static `import`/`export ... from` of a relative path. */
function staticImports(file: string): string[] {
  const source = fs.readFileSync(path.join(dir, file), "utf8");
  return [
    ...source.matchAll(
      /(?:^|[;}])\s*(?:import|export\s*(?:\*|\{[^}]*\}))\s*(?:[\w*{},\s]*?from\s*)?"(\.\.?\/[^"]+\.js)"/g,
    ),
  ].map((match) => match[1]!);
}

describe.skipIf(!built)("agent pane page", () => {
  test("loads pane.js as one classic script and preloads nothing else", () => {
    const html = fs.readFileSync(page, "utf8");
    expect(html).toContain('<script src="pane.js"></script>');
    expect(html).not.toContain('type="module"');
    expect(html).not.toContain("modulepreload");
    expect([...html.matchAll(/<link rel="preload"[^>]*>/g)].map((match) => match[0])).toEqual([
      '<link rel="preload" as="script" href="pane.js" />',
    ]);
  });

  test("pane.js imports no module, and a chunk imports no other than a chunk", () => {
    const entry = fs.readFileSync(path.join(dir, "pane.js"), "utf8");
    // A static import or export-from at the top level makes it a module: a classic script is a syntax error.
    expect(() => new Function(entry)).not.toThrow();
    expect(entry).not.toMatch(/import\.meta/);
    const chunks = fs.readdirSync(path.join(dir, "chunks")).filter((name) => name.endsWith(".js"));
    expect(chunks.length).toBeGreaterThan(0);
    for (const name of chunks) {
      for (const imported of staticImports(`chunks/${name}`)) {
        // Only another lazy chunk: every shared chunk is inside pane.js (the registry), none is a file.
        expect(fs.existsSync(path.join(dir, "chunks", imported))).toBe(true);
      }
    }
  });
});
