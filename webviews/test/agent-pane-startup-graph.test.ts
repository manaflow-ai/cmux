// The agent pane's first script is main.tsx and every module it imports statically; an import() is a
// chunk loaded when used (cmuxterm-hq finding 2026-11-19-agent-pane-startup-graph). The views below
// were moved behind an import() so the chat's first paint does not parse them: this walks the
// pane's static import graph from its source and fails when one of them is back in it.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const webviews = path.resolve(import.meta.dir, "..");
const entry = path.join(webviews, "src/agent-session/acpmux/main.tsx");

/** Modules that load on use, never in pane.js, each with why. */
const LAZY: Record<string, string> = {
  "src/agent-session/acpmux/session-info/native/NativeSessionInfo.tsx":
    "Session Info drawn by the App: only once the host says so (LazyNativeSessionInfo.tsx)",
  "src/agent-session/acpmux/CloudEnvironmentEditorContent.tsx": "the Cloud environment editor: only when opened",
  "src/agent-session/acpmux/conversation/artifactJsx.ts": "the artifact runtime: only for a JSX artifact",
};

// The classic JSX runtime: scanImports only reads imports, and the automatic runtime throws on a
// `key` after a {...spread} ("deprecated in JSX") in some pane modules, which ends the walk.
const classicJsx = { compilerOptions: { jsx: "react" as const } };
const transpilers = {
  ts: new Bun.Transpiler({ loader: "ts", tsconfig: classicJsx }),
  tsx: new Bun.Transpiler({ loader: "tsx", tsconfig: classicJsx }),
};

/** Every first-party module `entry` reaches through static imports (type-only imports are erased). */
function staticClosure(start: string): Set<string> {
  const seen = new Set([start]);
  const queue = [start];
  while (queue.length) {
    const file = queue.shift()!;
    const ext = path.extname(file);
    if (ext !== ".ts" && ext !== ".tsx") continue;
    const imports = transpilers[ext === ".tsx" ? "tsx" : "ts"].scanImports(readFileSync(file, "utf8"));
    for (const item of imports) {
      if (item.kind !== "import-statement") continue;
      if (!item.path.startsWith(".")) continue;
      let resolved: string;
      try {
        resolved = Bun.resolveSync(item.path, path.dirname(file));
      } catch {
        continue; // a virtual module or a build-time alias: not first-party source
      }
      if (seen.has(resolved) || resolved.includes("/node_modules/")) continue;
      seen.add(resolved);
      queue.push(resolved);
    }
  }
  return seen;
}

describe("agent pane startup graph", () => {
  const closure = staticClosure(entry);

  test("walks the pane's graph", () => {
    // A sanity floor: the walk found the pane, not just its entry.
    expect(closure.size).toBeGreaterThan(500);
  });

  for (const [file, why] of Object.entries(LAZY)) {
    test(`${path.basename(file)} is not in pane.js (${why})`, () => {
      expect(readFileSync(path.join(webviews, file), "utf8").length).toBeGreaterThan(0);
      expect(closure.has(path.join(webviews, file))).toBe(false);
    });
  }
});
