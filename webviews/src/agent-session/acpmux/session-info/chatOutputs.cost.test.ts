// Session Info's Outputs is read on every update that reaches the pane while a reply streams
// (SessionInfo.tsx `outputFiles`). Its cost per update must not grow with the chat's history (Leo,
// 2026-11-04: "It should just never, ever ... be acceptable for there to be some sort of linear time
// growth degradation"): review of #37575 measured about 51 ms per call over ten past 500-line
// rewrites, each diffed again on every update though a code file is never an output.
//
// A chat of N past turns, each a reply and a Write that rewrote a 500-line file, then one update: the
// streaming reply grew. Each past file's texts count the reads they get (a diff of a file reads both);
// the update must read none of them, at N = 10 as at N = 100.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnFiles } from "../diff";
import { chatOutputs } from "./chatOutputs";

const lines = (seed: string) => Array.from({ length: 500 }, (_, index) => `${seed} line ${index}`).join("\n");

/// A past turn: its reply, and a Write that rewrote `src/file{n}.ts` (whose texts count their reads).
function pastTurn(n: number, reads: { count: number }): AcpmuxRow[] {
  const oldText = lines(`old ${n}`);
  const newText = lines(`new ${n}`);
  const diff = {
    path: `/repo/src/file${n}.ts`,
    get oldText() {
      reads.count += 1;
      return oldText;
    },
    get newText() {
      reads.count += 1;
      return newText;
    },
  };
  return [
    {
      id: `reply-${n}`,
      version: 1,
      at: n,
      kind: "assistant",
      text: `Rewrote \`src/file${n}.ts\` and saved [notes](notes${n}.pdf).`,
    },
    {
      id: `activity-${n}`,
      version: 1,
      at: n,
      kind: "activity",
      items: [
        { kind: "tool", tool: { id: `write-${n}`, kind: "edit", title: "Write", status: "completed", diffs: [diff] } },
      ],
    } as unknown as AcpmuxRow,
  ];
}

/// One streamed update over a chat of `turns` past rewrites: the reads and the time it costs.
function update(turns: number) {
  const reads = { count: 0 };
  const history = Array.from({ length: turns }, (_, n) => pastTurn(n, reads)).flat();
  const streaming = (text: string): AcpmuxRow => ({
    id: "live",
    version: text.length,
    at: turns,
    kind: "assistant",
    text,
    streaming: true,
  });
  // The update before: the panel has read the chat once.
  const before = chatOutputs([...history, streaming("Working on")], "/repo");
  reads.count = 0;
  const started = performance.now();
  const after = chatOutputs([...history, streaming("Working on it")], "/repo");
  const ms = performance.now() - started;
  return { reads: reads.count, ms, before, after };
}

test("one streamed update reads no past diff, however long the chat", () => {
  const ten = update(10);
  const hundred = update(100);
  console.log(
    `OUTPUTS-COST ${JSON.stringify({ n10: { reads: ten.reads, ms: +ten.ms.toFixed(2) }, n100: { reads: hundred.reads, ms: +hundred.ms.toFixed(2) } })}`,
  );
  // Every reply's linked document is an output; no rewritten code file is.
  expect(hundred.after.map((output) => output.displayPath)).toHaveLength(100);
  expect(hundred.after.every((output) => output.path.endsWith(".pdf"))).toBe(true);
  expect(hundred.after).toEqual(hundred.before);
  expect(ten.reads, "past diff texts read for one update, N = 10").toBe(0);
  expect(hundred.reads, "past diff texts read for one update, N = 100").toBe(0);
});

test("the files it counts are the ones turnFiles counts", () => {
  const tool = (id: string, status: string, diffs: object[]) =>
    ({
      id: `a-${id}`,
      version: 1,
      at: 0,
      kind: "activity",
      items: [{ kind: "tool", tool: { id, kind: "edit", title: "Write", status, diffs } }],
    }) as unknown as AcpmuxRow;
  const rows = [
    tool("new", "completed", [{ path: "/repo/a.md", newText: "a" }]),
    tool("edited", "completed", [{ path: "/repo/b.md", oldText: "b", newText: "c" }]),
    tool("fragment", "completed", [{ path: "/repo/c.md", newText: "c", fragment: true }]),
    tool("unknown", "completed", [{ path: "/repo/d.png", newText: "d", fragment: true }]),
    tool("then-made", "completed", [{ path: "/repo/d.png", newText: "d" }]),
    tool("failed-unknown", "failed", [{ path: "/repo/e.csv", newText: "e", fragment: true }]),
    tool("failed-made", "failed", [{ path: "/repo/e.csv", newText: "e" }]),
    tool("pending", "pending", [{ path: "/repo/f.md", newText: "f" }]),
    tool("spelled", "completed", [{ path: "/repo/G.md", canonical: "/repo/g.md", newText: "g" }]),
    tool("respelled", "completed", [{ path: "/repo/g.md", canonical: "/repo/g.md", oldText: "g", newText: "h" }]),
    tool("from-input", "completed", [{ path: "/repo/h.xlsx", newText: "h", fragment: true, fromInput: true }]),
  ];
  expect(chatOutputs(rows, "/repo")).toEqual(chatOutputs(rows, "/repo", turnFiles(rows)));
  expect(chatOutputs(rows, "/repo").map((output) => output.displayPath)).toEqual(["a.md", "e.csv", "G.md"]);
});
