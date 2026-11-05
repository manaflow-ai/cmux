import { expect, test } from "bun:test";
import { RunMessageCache, stepMessage } from "../src/pages/home-channels/runMessages";
import type { HomeRunStep } from "../src/pages/home-channels/types";

function tool(id: string, input: unknown, rev = 1): HomeRunStep {
  return {
    id,
    seq: 1,
    at: 1,
    rev,
    kind: "tool",
    status: "done",
    tool: { name: "mcp__optchat__tell", input, files: [] },
    attachments: [],
    links: [],
  };
}

test("appending a step does not serialize historical tool inputs again", () => {
  let reads = 0;
  const prior = tool("old", {
    toJSON: () => {
      reads++;
      return { id: "a1", message: "Keep the history" };
    },
  });
  const cache = new RunMessageCache();
  const first = cache.classify([prior]);
  const initialReads = reads;
  expect(initialReads).toBeGreaterThan(0);
  const next = cache.classify([{ ...prior }, tool("new", { id: "a2", message: "New work" })]);
  expect(reads).toBe(initialReads);
  expect(next.messages[0]!.message).toBe(first.messages[0]!.message);
  expect(next.messages).toHaveLength(2);
  cache.classify([{ ...prior, rev: 2 }]);
  expect(reads).toBeGreaterThan(initialReads);
});

test("unversioned replacement steps refresh delivery results and removed steps are evicted", () => {
  const cache = new RunMessageCache();
  const old = tool("tell", { id: "a1", message: "Check this" }, 0);
  const first = cache.classify([old]).messages[0]!.message;
  expect(cache.classify([old]).messages[0]!.message).toBe(first);
  const refused = { ...old, tool: { ...old.tool!, output: "outcome: refused. Agent was cancelled" } };
  expect(cache.classify([refused]).messages[0]!.message).toEqual(stepMessage(refused)!);
  expect(cache.classify([refused]).messages[0]!.message).not.toBe(first);
  cache.classify([]);
  expect(cache.classify([old]).messages[0]!.message).not.toBe(first);
});

test("changing run identity invalidates colliding step ids", () => {
  const cache = new RunMessageCache();
  const first = cache.classify([tool("tell", { id: "a1", message: "First run" })], "run1");
  const next = cache.classify([tool("tell", { id: "a1", message: "Next run" })], "run2");
  expect(next.messages[0]!.message).not.toBe(first.messages[0]!.message);
});

// Same payload and update stream for the old classification loop and its cached replacement.
// Report timing for review; the deterministic regression above gates reprocessing, not wall time.
test("measure message classification during appended run updates", () => {
  const payload = "patch content\n".repeat(2500);
  const history = Array.from({ length: 300 }, (_, i) => ({
    ...tool(`write-${i}`, { file_path: `file-${i}`, content: payload }),
    tool: { name: "write_file", input: { file_path: `file-${i}`, content: payload }, files: [] },
  }));
  const updates = Array.from({ length: 30 }, (_, i) => tool(`tell-${i}`, { id: "a1", message: `Check ${i}` }));
  const measure = (cached: boolean) => {
    const cache = new RunMessageCache();
    let steps: HomeRunStep[] = [...history];
    if (cached) cache.classify(steps);
    else steps.map(stepMessage);
    const start = performance.now();
    for (const update of updates) {
      steps = [...steps, update];
      if (cached) cache.classify(steps);
      else steps.map(stepMessage);
    }
    return performance.now() - start;
  };
  const before = measure(false);
  const after = measure(true);
  console.log(
    `Run message classification: 300 x ${payload.length} chars, 30 appends; before=${before.toFixed(2)}ms after=${after.toFixed(2)}ms delta=${(after - before).toFixed(2)}ms`,
  );
});
