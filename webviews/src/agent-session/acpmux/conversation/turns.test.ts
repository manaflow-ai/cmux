import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { formatDuration, turnView, workedLabel } from "./turns";

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({ id, version: 1, at, kind, ...extra });
const edit = { kind: "tool", text: "Edit a.ts", tool: { id: "e", title: "Edit a.ts", kind: "edit", status: "completed" } };
const read = { kind: "tool", text: "Read a.ts", tool: { id: "r", title: "Read a.ts", kind: "read", status: "completed" } };
const turn = [
  row("u", "user", 0, { text: "fix it" }),
  row("c", "assistant", 1_000, { text: "I'll look." }),
  row("t", "activity", 2_000, { items: [read], toolCount: 1 }),
  row("e", "activity", 3_000, { items: [edit], toolCount: 1 }),
  row("a", "assistant", 15_000, { text: "Done." }),
  row("s", "turnSummary", 54_000, { durationMs: 54_000, toolCount: 2, status: "completed" }),
];
const ids = (rows: AcpmuxRow[]) => rows.map((entry) => entry.id);

describe("turn view", () => {
  test("a finished turn folds its work under Worked for, timed to the answer", () => {
    const view = turnView(turn, new Set());
    expect(ids(view)).toEqual(["u", "worked-u", "a", "e", "s"]);
    expect(workedLabel(view[1]!)).toBe("Worked for 15s · 2 tool calls");
    // The footer copies the answer and does not repeat the fold's time.
    expect(view.at(-1)).toMatchObject({ text: "Done.", folded: true });
  });

  test("opening the fold shows the work in order; edits stay as the card after the answer", () => {
    const view = turnView(turn, new Set(["worked-u"]));
    expect(ids(view)).toEqual(["u", "worked-u", "c", "t", "e:fold", "a", "e", "s"]);
  });

  test("a running turn shows its work as it happens", () => {
    expect(ids(turnView(turn.slice(0, 4), new Set()))).toEqual(["u", "c", "t", "e"]);
  });

  test("a turn with nothing before its answer has no fold", () => {
    const view = turnView([turn[0]!, turn[4]!, turn[5]!], new Set());
    expect(ids(view)).toEqual(["u", "a", "s"]);
    expect(view.at(-1)?.folded).toBe(false);
  });

  test("a turn that ended without an answer folds all of its work", () => {
    const view = turnView([turn[0]!, turn[2]!, turn[5]!], new Set());
    expect(ids(view)).toEqual(["u", "worked-u", "s"]);
    expect(workedLabel(view[1]!)).toBe("Worked for 54s · 2 tool calls");
  });

  test("rows before the first prompt draw as they are", () => {
    expect(ids(turnView([row("g", "assistant", 0, { text: "hi" }), ...turn.slice(0, 1)], new Set()))).toEqual(["g", "u"]);
  });

  test("a stopped turn says so", () => {
    const view = turnView([...turn.slice(0, 5), { ...turn[5]!, status: "cancelled" }], new Set());
    expect(workedLabel(view[1]!)).toBe("You stopped after 15s · 2 tool calls");
  });

  test("durations read as Codex writes them", () => {
    expect([0, 999, 15_000, 76_000, 3_780_000].map(formatDuration)).toEqual(["0s", "0s", "15s", "1m 16s", "1h 3m"]);
  });
});
