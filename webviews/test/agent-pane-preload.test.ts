// The agent pane's first chat paint waits for pane.js and every chunk it imports statically. The
// page names each of them in a <link rel="modulepreload"> (bundle.mjs --preload-list,
// build-agent-pane-web.sh), so they load and parse beside pane.js. Without the links Chromium
// learns of the chunks only once pane.js has loaded and parsed, and fetches them a round later
// (chunks first requested about 70 ms after pane.js in the chat-load bench).
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

/** The files `file` imports statically (`import "./x.js"`, `from "./x.js"`), relative to `dir`;
 * `import("./x.js")` loads when used and is left out. */
function staticImports(file: string): string[] {
  const source = fs.readFileSync(path.join(dir, file), "utf8");
  return [...source.matchAll(/\b(?:from|import)\s*"(\.\/[^"]+\.js)"/g)].map((match) =>
    path.posix.join(path.posix.dirname(file), match[1]!),
  );
}

describe.skipIf(!built)("agent pane page", () => {
  test("preloads pane.js and every chunk it imports statically, and nothing it loads on use", () => {
    const closure = new Set<string>();
    const queue = ["pane.js"];
    while (queue.length) {
      for (const file of staticImports(queue.shift()!)) {
        if (closure.has(file)) continue;
        closure.add(file);
        queue.push(file);
      }
    }
    expect(closure.size).toBeGreaterThan(0);
    const preloaded = [...fs.readFileSync(page, "utf8").matchAll(/<link rel="modulepreload" href="([^"]+)" \/>/g)].map(
      (match) => match[1]!,
    );
    expect(preloaded[0]).toBe("pane.js");
    expect(new Set(preloaded.slice(1))).toEqual(closure);
    for (const file of preloaded) expect(fs.existsSync(path.join(dir, file))).toBe(true);
  });
});
