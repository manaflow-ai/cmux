import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { DATE, formatDuration, turnView as shape, workedLabel } from "./turns";
import { dateLabel } from "./DateLine";

/// The turn shape without its date lines, which "date lines" covers.
const turnView = (...args: Parameters<typeof shape>) => shape(...args).filter((entry) => entry.kind !== DATE);

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind,
  ...extra,
});
const edit = {
  kind: "tool",
  text: "Edit a.ts",
  tool: { id: "e", title: "Edit a.ts", kind: "edit", status: "completed" },
};
const read = {
  kind: "tool",
  text: "Read a.ts",
  tool: { id: "r", title: "Read a.ts", kind: "read", status: "completed" },
};
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
    expect(ids(turnView([row("g", "assistant", 0, { text: "hi" }), ...turn.slice(0, 1)], new Set()))).toEqual([
      "g",
      "u",
    ]);
  });

  test("a stopped turn says so", () => {
    const view = turnView([...turn.slice(0, 5), { ...turn[5]!, status: "cancelled" }], new Set());
    expect(workedLabel(view[1]!)).toBe("You stopped after 15s · 2 tool calls");
  });

  test("rows after a turn's summary still draw", () => {
    const late = row("late", "activity", 60_000, { items: [read] });
    const again = row("s2", "turnSummary", 70_000, { status: "completed" });
    expect(ids(turnView([...turn, late, again], new Set()))).toEqual(["u", "worked-u", "a", "e", "s", "late", "s2"]);
  });

  test("a prompt sent while a turn runs waits after it instead of taking over its rows", () => {
    const queued = row("local-1", "user", 1_500, { text: "also this", pending: true });
    const view = turnView([...turn.slice(0, 2), queued, ...turn.slice(2)], new Set());
    expect(ids(view)).toEqual(["u", "worked-u", "a", "e", "s", "local-1"]);
    expect(workedLabel(view[1]!)).toBe("Worked for 15s · 2 tool calls");
  });

  test("the fold line and footer change version when what they draw changes", () => {
    const before = turnView(turn, new Set());
    const streamed = turnView(
      turn.map((entry) => (entry.id === "a" ? { ...entry, version: 2, text: "Done. More." } : entry)),
      new Set(),
    );
    const settled = turnView(
      turn.map((entry) => (entry.id === "s" ? { ...entry, version: 2, toolCount: 3 } : entry)),
      new Set(),
    );
    const opened = turnView(turn, new Set(["worked-u"]));
    for (const id of ["worked-u", "s"]) {
      const version = (rows: AcpmuxRow[]) => rows.find((entry) => entry.id === id)!.version;
      expect(new Set([version(before), version(streamed), version(settled)]).size).toBe(3);
    }
    expect(opened[1]!.version).not.toBe(before[1]!.version);
  });

  test("durations read as Codex writes them", () => {
    expect([0, 999, 15_000, 76_000, 3_780_000].map(formatDuration)).toEqual(["0s", "0s", "15s", "1m 16s", "1h 3m"]);
  });
});

describe("date lines", () => {
  const at = (day: number, hour: number) => new Date(2026, 8, day, hour, 55).getTime();
  const prompt = (id: string, when: number) => row(id, "user", when, { text: id });
  const dates = (rows: AcpmuxRow[]) =>
    shape(rows, new Set()).flatMap((entry) => (entry.kind === DATE ? [entry.id] : []));

  test("the first prompt of each day is dated", () => {
    const rows = [prompt("a", at(13, 19)), prompt("b", at(13, 21)), prompt("c", at(14, 9)), prompt("d", at(14, 10))];
    expect(dates(rows)).toEqual(["date-a", "date-c"]);
    // The line sits right above its prompt.
    expect(ids(shape(rows, new Set())).slice(0, 2)).toEqual(["date-a", "a"]);
  });

  test("rows before the first prompt are not dated", () => {
    expect(ids(shape([row("g", "assistant", at(13, 8)), prompt("a", at(13, 9))], new Set()))).toEqual([
      "g",
      "date-a",
      "a",
    ]);
  });

  test("the label reads as Codex's, with the year only when it is not this one", () => {
    const label = dateLabel(at(13, 19), at(20, 9));
    expect(label).toMatch(/^Sun, Sep 13 at 7:55\sPM$/);
    expect(dateLabel(new Date(2025, 8, 13, 19, 55).getTime(), at(20, 9))).toContain("2025");
  });
});
