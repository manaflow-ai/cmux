// Read the shipped JavaScript, including every eager shared chunk: moving mock code out of
// pane.js alone must not pass if the page still imports it before its first frame.
import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, resolve } from "node:path";

const bundle = resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane");
const entry = resolve(bundle, "pane.js");
const built = existsSync(entry);
if (!built && process.env.CI) throw new Error("Build the agent pane before checking its startup bundle");

function eagerSources(): string[] {
  const seen = new Set<string>();
  const queue = [entry];
  const sources: string[] = [];
  const scanner = new Bun.Transpiler({ loader: "js" });
  while (queue.length) {
    const file = queue.pop()!;
    if (seen.has(file)) continue;
    seen.add(file);
    const source = readFileSync(file, "utf8");
    sources.push(source);
    for (const item of scanner.scanImports(source)) {
      if (item.kind === "import-statement" && item.path.startsWith(".")) queue.push(resolve(dirname(file), item.path));
    }
  }
  return sources;
}

describe.skipIf(!built)("agent pane startup bundle", () => {
  test("mock transport and shared-chat fixtures ship only in lazy chunks", () => {
    const sources = eagerSources();
    const eager = sources.join("\n");
    const chunks = readdirSync(resolve(bundle, "chunks"))
      .filter((name) => name.endsWith(".js"))
      .map((name) => readFileSync(resolve(bundle, "chunks", name), "utf8"))
      .join("\n");
    console.info(JSON.stringify({ eager_files: sources.length, eager_bytes: Buffer.byteLength(eager) }));
    // These are data the mock transport and shared fixture actually consume, not source symbols
    // that a minifier can rename. The second assertion ensures the fixtures remain available.
    for (const value of ["ws://mock.invalid/acp", "guest:shared-share.shared-guest"]) {
      expect(eager.includes(value)).toBe(false);
      expect(chunks.includes(value)).toBe(true);
    }
  });
});
