import { expect, test } from "bun:test";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (partial: Partial<AcpmuxRow> & Pick<AcpmuxRow, "id" | "kind" | "at">): AcpmuxRow => ({
  version: 1,
  ...partial,
});

test("a minimap card keeps the turn metadata needed for a compact hover summary", () => {
  const rows: AcpmuxRow[] = [
    row({
      id: "u1",
      kind: "user",
      at: 1_700_000_000_000,
      text: "Review https://github.com/manaflow-ai/cmux/pull/25794",
    }),
    row({
      id: "a1",
      kind: "activity",
      at: 1_700_000_010_000,
      items: [
        {
          kind: "tool",
          text: "edit",
          tool: {
            id: "t1",
            title: "Edit",
            status: "completed",
            diffs: [{ path: "src/App.tsx", newText: "next" }],
            locations: [{ path: "src/App.tsx" }, { path: "README.md" }],
          },
        },
      ],
    }),
    row({
      id: "reply",
      kind: "assistant",
      at: 1_700_000_020_000,
      text: "**Ready**\n\nThe card keeps the useful Markdown preview.",
    }),
    row({
      id: "summary",
      kind: "turnSummary",
      at: 1_700_000_042_000,
      status: "failed",
      durationMs: 42_000,
      toolCount: 3,
      error: "peer disconnected while waiting for the agent to answer",
    }),
  ];
  expect(minimapTurns(rows).turns[0]?.metadata).toEqual({
    at: 1_700_000_000_000,
    durationMs: 42_000,
    toolCount: 3,
    fileCount: 1,
    links: ["https://github.com/manaflow-ai/cmux/pull/25794"],
    failed: true,
    failure: "peer disconnected while waiting for the agent to answer",
  });
});

test("streaming reuses metadata without reading old tool items, and a dropped summary leaves the committed card alone", () => {
  let reads = 0;
  const activity = row({ id: "tools", kind: "activity", at: 2 });
  Object.defineProperty(activity, "items", {
    get: () => {
      reads += 1;
      return [
        {
          kind: "tool",
          text: "edit",
          tool: { id: "t", title: "Edit", status: "completed", diffs: [{ path: "a.ts" }] },
        },
      ];
    },
  });
  let rows = [
    row({ id: "u", kind: "user", at: 1, text: "Review this" }),
    activity,
    row({ id: "r", kind: "assistant", at: 3, streaming: true, text: "Already visible. ".repeat(50) }),
  ];
  let committed = minimapTurns(rows, "s");
  const metadata = committed.turns[0]!.metadata;
  const initialReads = reads;
  for (let token = 0; token < 20; token += 1) {
    const next = [...rows.slice(0, -1), { ...rows.at(-1)!, text: `${rows.at(-1)!.text} more`, version: token + 2 }];
    committed = minimapTurns(next, "s", committed, { base: rows, rows: next, from: 2 });
    expect(committed.turns[0]!.metadata).toBe(metadata);
    rows = next;
  }
  expect(reads).toBe(initialReads);
  const turn = committed.turns[0]!;
  const ended = [...rows, row({ id: "end", kind: "turnSummary", at: 4, status: "failed", error: "disconnected" })];
  const dropped = minimapTurns(ended, "s", committed, { base: rows, rows: ended, from: rows.length });
  expect(dropped.turns[0]!.metadata?.failure).toBe("disconnected");
  expect(committed.turns[0]).toBe(turn);
  expect(turn.metadata).toBe(metadata);
  expect(turn.metadata?.failure).toBeUndefined();
});
