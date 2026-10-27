import { expect, test } from "bun:test";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

const row = (partial: Partial<AcpmuxRow> & Pick<AcpmuxRow, "id" | "kind" | "at">): AcpmuxRow => ({
  version: 1,
  ...partial,
});

test("a received message's card retains its sender without changing prompt ticks", () => {
  const rows = [
    row({
      id: "received",
      kind: "user",
      at: 1,
      text: "Review complete.",
      incoming: {
        kind: "message",
        message: { name: "peer/pr-row", sessionId: "review", text: "Review complete.", raw: "Review complete." },
      },
    }),
  ];
  const turns = minimapTurns(rows, "current");
  expect(turns.turns[0]?.metadata?.sender).toEqual({ name: "peer/pr-row", sessionId: "review", relation: undefined });
  expect(turns.turns[0]?.id).toBe("received");
  expect(turns.ticks[0]?.id).toBe("received");
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

test("production turnView wrappers keep metadata without re-reading earlier tool diffs", () => {
  let reads = 0;
  const tool = { id: "edit", title: "Edit", status: "completed", kind: "edit" };
  Object.defineProperty(tool, "diffs", {
    get: () => {
      reads += 1;
      return [{ path: "a.ts", newText: "next" }];
    },
  });
  const activity = row({ id: "activity", kind: "activity", at: 2, items: [{ kind: "tool", text: "Edit", tool }] });
  let raw = [
    row({ id: "user-1", kind: "user", at: 1, text: "Review" }),
    activity,
    row({ id: "reply", kind: "assistant", at: 3, text: "Visible answer. ".repeat(40), streaming: true }),
  ];
  const options = { working: true, liveRuns: true };
  let shaped = turnView(raw, new Set(), options);
  const wrapper = shaped.find((item) => item.kind === "activity")!;
  expect(wrapper).toBeDefined();
  expect(wrapper).not.toBe(activity);
  let committed = minimapTurns(shaped, "production");
  const metadata = committed.turns[0]!.metadata;
  expect(metadata?.fileCount).toBe(1);
  for (let token = 0; token < 20; token += 1) {
    raw = [...raw.slice(0, -1), { ...raw.at(-1)!, text: `${raw.at(-1)!.text} more`, version: token + 2 }];
    const next = turnView(raw, new Set(), options);
    expect(next.find((item) => item.kind === "activity")).not.toBe(shaped.find((item) => item.kind === "activity"));
    const before = reads;
    committed = minimapTurns(next, "production", committed);
    expect(reads).toBe(before);
    expect(committed.turns[0]!.metadata).toBe(metadata);
    shaped = next;
  }
});

test("a completed merged edit card cannot reuse a live run with the same derived revision", () => {
  const user = row({ id: "user", kind: "user", at: 1, text: "Edit two files" });
  const edit = (id: string, version: number, path: string) =>
    row({
      id,
      version,
      kind: "activity",
      at: 2,
      items: [
        {
          kind: "tool",
          text: "Edit",
          tool: { id, title: "Edit", kind: "edit", status: "completed", diffs: [{ path, newText: "next" }] },
        },
      ],
    });
  const reply = row({
    id: "reply",
    kind: "assistant",
    at: 3,
    text: "The files are ready. ".repeat(20),
    streaming: true,
  });
  const source = [user, edit("A", 3, "a.ts"), edit("B", 5, "b.ts"), reply];
  const live = turnView(source, new Set(), { working: true, liveRuns: true });
  const previous = minimapTurns(live, "collision");
  const ended = turnView(
    [
      ...source.slice(0, -1),
      { ...reply, streaming: false },
      row({ id: "end", kind: "turnSummary", at: 4, status: "completed" }),
    ],
    new Set(),
    { liveRuns: true },
  );
  const liveA = live.find((item) => item.id === "A")!;
  const endedA = ended.find((item) => item.id === "A")!;
  expect(liveA.version).toBe(17);
  expect(endedA.version).toBe(liveA.version);
  expect(endedA.ended).toBe(true);
  expect(minimapTurns(ended, "collision", previous).turns[0]!.metadata?.fileCount).toBe(2);
});
