import { describe, expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import type { AcpmuxRow } from "../model";
import { DATE, formatDuration, turnView as shape, workedLabel } from "./turns";
import { timestampText, timestampTurns } from "./timestamps";

const english = translatorFor("en");

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
    expect(workedLabel(english, view[1]!)).toBe("Worked for 15s");
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

  test("a running turn says Thinking until it has output, then Working over its work", () => {
    const typing = row("typing", "typing", 500);
    expect(ids(turnView([turn[0]!, typing], new Set(), { working: true }))).toEqual(["u", "thinking-u"]);
    expect(ids(turnView([turn[0]!], new Set(), { working: true }))).toEqual(["u", "thinking-u"]);
    const view = turnView([turn[0]!, typing, ...turn.slice(1, 4)], new Set(), { working: true });
    expect(ids(view)).toEqual(["u", "working-u", "c", "t", "e"]);
    // Timed from the prompt, and steady across updates so the row keeps its own clock.
    expect(view[1]).toMatchObject({ at: 0, version: 1 });
  });

  test("only the last turn is live, and only while the session works", () => {
    const next = [row("u2", "user", 60_000, { text: "again" }), row("t2", "activity", 61_000, { items: [read] })];
    expect(ids(turnView([...turn, ...next], new Set(), { working: true }))).toEqual([
      "u",
      "worked-u",
      "a",
      "e",
      "s",
      "u2",
      "working-u2",
      "t2",
    ]);
    expect(ids(turnView([...turn, ...next], new Set(), { working: false }))).toEqual([
      "u",
      "worked-u",
      "a",
      "e",
      "s",
      "u2",
      "t2",
    ]);
    // A turn that ended has its fold, whatever the flag says.
    expect(ids(turnView(turn, new Set(), { working: true }))).toEqual(["u", "worked-u", "a", "e", "s"]);
  });

  test("a running turn shapes its status the way it will fold", () => {
    // Only an answer so far: it will end without a fold, so no status line comes and goes.
    expect(ids(turnView([turn[0]!, turn[1]!], new Set(), { working: true }))).toEqual(["u", "c"]);
    // Text after work: the clock holds at the text's start, where Worked for would time it.
    const answering = turnView(turn.slice(0, 5), new Set(), { working: true });
    expect(ids(answering)).toEqual(["u", "working-u", "c", "t", "e", "a"]);
    expect(answering[1]).toMatchObject({ durationMs: 15_000, version: 2 });
    expect(workedLabel(english, turnView(turn, new Set())[1]!)).toStartWith("Worked for 15s");
    // While a tool runs, the line ticks on its own clock.
    expect(turnView(turn.slice(0, 4), new Set(), { working: true })[1]?.durationMs).toBeUndefined();
  });

  test("a prompt sent while the turn runs draws after its status", () => {
    const held = row("p", "user", 500, { text: "also this", pending: true });
    expect(ids(turnView([turn[0]!, held], new Set(), { working: true }))).toEqual(["u", "thinking-u", "p"]);
  });

  test("a turn with nothing before its answer has no fold", () => {
    const view = turnView([turn[0]!, turn[4]!, turn[5]!], new Set());
    expect(ids(view)).toEqual(["u", "a", "s"]);
    expect(view.at(-1)?.folded).toBe(false);
  });

  test("a turn that ended without an answer folds all of its work", () => {
    const view = turnView([turn[0]!, turn[2]!, turn[5]!], new Set());
    expect(ids(view)).toEqual(["u", "worked-u", "s"]);
    expect(workedLabel(english, view[1]!)).toBe("Worked for 54s");
  });

  test("rows before the first prompt draw as they are", () => {
    expect(ids(turnView([row("g", "assistant", 0, { text: "hi" }), ...turn.slice(0, 1)], new Set()))).toEqual([
      "g",
      "u",
    ]);
  });

  test("a stopped turn says so", () => {
    const view = turnView([...turn.slice(0, 5), { ...turn[5]!, status: "cancelled" }], new Set());
    expect(workedLabel(english, view[1]!)).toBe("You stopped after 15s");
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
    expect(workedLabel(english, view[1]!)).toBe("Worked for 15s");
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

  test("only the last turn's footer carries its prompt, and it drops it when a later prompt goes", () => {
    const footer = (rows: AcpmuxRow[], id: string) => turnView(rows, new Set()).find((entry) => entry.id === id)!;
    expect(footer(turn, "s").prompt).toBe("fix it");
    const next = [...turn, row("u2", "user", 90_000, { text: "and the docs" })];
    expect(footer(next, "s").prompt).toBeUndefined();
    expect(footer(next, "s").version).not.toBe(footer(turn, "s").version);
  });

  test("no Retry while a later prompt waits to be accepted", () => {
    const queued = row("local-1", "user", 90_000, { text: "also this", pending: true });
    expect(turnView([...turn, queued], new Set()).find((entry) => entry.id === "s")!.prompt).toBeUndefined();
  });

  test("an ended turn's card holds every edit, after the answer too, and offers Undo", () => {
    const late = row("e2", "activity", 20_000, { items: [{ ...edit, tool: { ...edit.tool, id: "e2" } }] });
    const ended = [...turn.slice(0, -1), late, turn.at(-1)!];
    const card = turnView(ended, new Set()).find((entry) => entry.id === "e")!;
    expect(card.ended).toBe(true);
    expect(card.items!.map((item) => item.tool!.id)).toEqual(["e", "e2"]);
    expect(ids(turnView(ended, new Set()))).not.toContain("e2");
    // The live edit row and the card it becomes differ in version, so the card redraws with Undo.
    const live = turnView(turn.slice(0, -1), new Set(), { working: true }).find((entry) => entry.id === "e")!;
    expect(live.ended).toBeUndefined();
    expect(turnView(turn, new Set()).find((entry) => entry.id === "e")!.version).not.toBe(live.version);
  });

  test("durations read as short units", () => {
    expect([0, 999, 15_000, 76_000, 3_780_000].map(formatDuration)).toEqual(["0s", "0s", "15s", "1m 16s", "1h 3m"]);
  });
});

describe("timestamp lines", () => {
  const HOUR = 36e5;
  const start = Date.UTC(2026, 8, 14, 2, 55); // Sun, Sep 13 at 7:55 PM in Los Angeles.
  const turnAt = (id: string, at: number, answerAfter?: number): AcpmuxRow[] => [
    row(id, "user", at, { text: id }),
    ...(answerAfter === undefined ? [] : [row(`${id}-a`, "assistant", at + answerAfter, { text: "ok" })]),
  ];
  const dated = (rows: AcpmuxRow[], now: number) =>
    shape(rows, new Set(), { now }).flatMap((entry) => (entry.kind === DATE ? [entry.id] : []));

  test("the thread's first prompt is dated once it is over an hour old", () => {
    const rows = turnAt("a", start, 60_000);
    expect(dated(rows, start + 30 * 60_000)).toEqual([]);
    expect(dated(rows, start + 2 * HOUR)).toEqual(["date-a"]);
    // The line sits right above its prompt.
    expect(ids(shape(rows, new Set(), { now: start + 2 * HOUR }))).toEqual(["date-a", "a", "a-a"]);
  });

  test("missing, zero or invalid times never add a date or an artificial gap", () => {
    for (const unknown of [undefined, 0, NaN, Infinity, 1e20]) {
      expect(timestampTurns([{ promptAt: unknown }], start, true)).toEqual([false]);
      expect(timestampTurns([{ promptAt: start, answerAt: start }, { promptAt: unknown }], start, true)).toEqual([
        false,
        false,
      ]);
      expect(
        timestampTurns(
          [{ promptAt: start, answerAt: unknown }, { promptAt: start + 2 * HOUR }],
          start + 2 * HOUR,
          true,
        ),
      ).toEqual([true, false]);
    }
    expect(dated(turnAt("unknown", 0), start)).toEqual([]);
  });

  test("a prompt more than an hour after the previous answer is dated; turns within the hour are not", () => {
    const rows = [
      ...turnAt("a", start, 60_000),
      ...turnAt("b", start + 30 * 60_000, 60_000),
      // 61 minutes after b's answer.
      ...turnAt("c", start + 31 * 60_000 + HOUR + 60_000, 60_000),
    ];
    expect(dated(rows, start + 3 * HOUR)).toEqual(["date-a", "date-c"]);
  });

  test("a day change alone draws no line, and a turn without an answer is measured from nothing", () => {
    const midnight = Date.UTC(2026, 8, 14, 6, 50);
    expect(
      dated([...turnAt("a", midnight, 60_000), ...turnAt("b", midnight + 20 * 60_000)], midnight + 30 * 60_000),
    ).toEqual([]);
    // b has no answer, so c's gap is not measured from b's prompt.
    const rows = [...turnAt("a", start, 60_000), ...turnAt("b", start + 10 * 60_000), ...turnAt("c", start + 5 * HOUR)];
    expect(dated(rows, start + 5 * HOUR)).toEqual(["date-a"]);
  });

  test("history that starts mid-turn does not date its first loaded prompt as the thread's first", () => {
    const rows = [row("g", "assistant", start - 60_000, { text: "earlier" }), ...turnAt("a", start, 60_000)];
    expect(dated(rows, start + 5 * HOUR)).toEqual([]);
  });

  test("the wording is Today, Yesterday, the weekday, then the date with ' at '", () => {
    const clock = { now: Date.UTC(2026, 8, 22, 19), timeZone: "America/Los_Angeles", locale: "en-US" };
    const text = (at: number) => timestampText(at, clock).replace(/\u202f/g, " ");
    expect(text(Date.UTC(2026, 8, 22, 16, 5))).toBe("Today 9:05 AM");
    expect(text(Date.UTC(2026, 8, 22, 3, 16))).toBe("Yesterday 8:16 PM");
    expect(text(Date.UTC(2026, 8, 18, 3, 16))).toBe("Thursday 8:16 PM");
    expect(text(start)).toBe("Sun, Sep 13 at 7:55 PM");
    expect(text(Date.UTC(2025, 8, 14, 2, 55))).toBe("Sep 13, 2025 at 7:55 PM");
  });
});
