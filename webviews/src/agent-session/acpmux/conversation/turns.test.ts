import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN } from "./backgroundTurns";
import { THINKING, WORKED, WORKING, turnView, turnViewFrom } from "./turns";

const user = (at: number): AcpmuxRow => ({ id: "user", version: 1, at, kind: "user", text: "resume" });

test("a resumed live turn counts from turn_started instead of its old prompt", () => {
  const rows: AcpmuxRow[] = [
    user(1_000),
    // direct.ts carries this timestamp from the live turn_started event in the snapshot.
    { id: "typing", version: 1, at: 100_000, kind: "typing" },
  ];
  const shown = turnView(rows, new Set(), { now: 200_000, working: true, turnStartedAtMs: 100_000 });
  expect(shown.find((row) => row.kind === THINKING)?.at).toBe(100_000);
});

test("a live turn with no start of its own counts from its prompt", () => {
  const rows: AcpmuxRow[] = [user(1_000), { id: "typing", version: 1, at: 100_000, kind: "typing" }];
  const shown = turnView(rows, new Set(), { now: 200_000, working: true });
  expect(shown.find((row) => row.kind === THINKING)?.at).toBe(1_000);
});

test("a completed turn has no live timer row", () => {
  const shown = turnView(
    [
      user(1_000),
      { id: "answer", version: 1, at: 5_000, kind: "assistant", text: "done" },
      { id: "summary", version: 1, at: 6_000, kind: "turnSummary", status: "completed", durationMs: 5_000 },
    ],
    new Set(),
    { now: 10_000, working: false, turnStartedAtMs: 1_000 },
  );
  expect(shown.some((row) => row.kind === THINKING || row.kind === WORKING)).toBe(false);
});

test("a partial same-chat refresh keeps an assistant row while tool rows arrive", () => {
  const folds = new Set<string>();
  const previous = turnViewFrom(
    [
      user(1_000),
      { id: "answer", version: 1, at: 2_000, kind: "assistant", text: "The answer is still on screen." },
      { id: "tool", version: 1, at: 3_000, kind: "activity", items: [], toolCount: 1 },
    ],
    folds,
  );
  // A refresh can publish the activity row before the reply body is present. The old visible
  // message must stay mounted until the replacement snapshot is complete.
  const refreshed = turnViewFrom(
    [user(1_000), { id: "tool", version: 2, at: 3_000, kind: "activity", items: [], toolCount: 1 }],
    folds,
    {},
    previous,
  );

  expect(refreshed.rows.some((row) => row.kind === "activity")).toBe(true);
  expect(refreshed.rows.some((row) => row.kind === "assistant" && row.text === "The answer is still on screen.")).toBe(
    true,
  );
  const visibleItems = (rows: readonly AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "user" || row.kind === "assistant" || row.kind === "activity").length;
  expect(visibleItems(refreshed.rows)).toBeGreaterThanOrEqual(visibleItems(previous.rows));
});

test("a partial refresh keeps a reply when its body is empty or its id is recreated", () => {
  const folds = new Set<string>();
  const previous = turnViewFrom(
    [
      user(1_000),
      { id: "answer", version: 1, at: 2_000, kind: "assistant", text: "Keep this answer." },
      { id: "tool", version: 1, at: 3_000, kind: "activity", items: [], toolCount: 1 },
    ],
    folds,
  );
  const empty = turnViewFrom(
    [
      user(1_000),
      { id: "answer", version: 2, at: 2_000, kind: "assistant", text: "" },
      { id: "tool", version: 2, at: 3_000, kind: "activity", items: [], toolCount: 1 },
    ],
    folds,
    {},
    previous,
  );
  const rekeyed = turnViewFrom(
    [
      user(1_000),
      { id: "answer-new", version: 1, at: 2_000, kind: "assistant", text: "New suffix." },
      { id: "tool", version: 3, at: 3_000, kind: "activity", items: [], toolCount: 1 },
    ],
    folds,
    {},
    previous,
  );
  expect(empty.rows.some((row) => row.kind === "assistant" && row.text === "Keep this answer.")).toBe(true);
  expect(empty.rows.filter((row) => row.kind === "assistant")).toHaveLength(1);
  expect(rekeyed.rows.some((row) => row.kind === "assistant" && row.text === "Keep this answer.")).toBe(true);
});

test("an activity-only update does not duplicate an unchanged reply", () => {
  const folds = new Set<string>();
  const previous = turnViewFrom(
    [
      user(1_000),
      { id: "answer", version: 1, at: 2_000, kind: "assistant", text: "Keep one copy." },
      { id: "tool-1", version: 1, at: 3_000, kind: "activity", items: [], toolCount: 1 },
      { id: "tool-2", version: 1, at: 4_000, kind: "activity", items: [], toolCount: 1 },
    ],
    folds,
  );
  const refreshed = turnViewFrom(
    [
      user(1_000),
      previous.source[1]!,
      previous.source[2]!,
      { id: "tool-2", version: 2, at: 4_000, kind: "activity", items: [], toolCount: 1 },
    ],
    folds,
    {},
    previous,
  );
  expect(refreshed.rows.filter((row) => row.kind === "assistant")).toHaveLength(1);
});

test("a superseded reply is not resurrected by a partial refresh", () => {
  const folds = new Set<string>();
  const previous = turnViewFrom(
    [
      user(1_000),
      { id: "old-answer", version: 1, at: 2_000, kind: "assistant", text: "Abandoned retry." },
      { id: "old-tool", version: 1, at: 3_000, kind: "activity", items: [], toolCount: 1 },
    ],
    folds,
  );
  const refreshed = turnViewFrom(
    [user(1_000), { id: "retry-tool", version: 1, at: 4_000, kind: "activity", items: [], toolCount: 1 }],
    folds,
    { supersededReplyIds: new Set(["old-answer"]) },
    previous,
  );
  expect(refreshed.rows.some((row) => row.id === "old-answer")).toBe(false);
});

test("the line under a streaming answer keeps the live turn start", () => {
  const shown = turnView(
    [
      user(1_000),
      { id: "tool", version: 1, at: 103_000, kind: "activity", items: [] },
      { id: "answer", version: 1, at: 105_000, kind: "assistant", text: "done" },
    ],
    new Set(),
    { now: 110_000, working: true, turnStartedAtMs: 100_000 },
  );
  expect(shown.find((row) => row.kind === THINKING)?.at).toBe(100_000);
});

test("a rebuild for a changed background fold keeps the live turn start", () => {
  const options = { now: 110_000, working: true, turnStartedAtMs: 100_000 };
  const folds = new Set<string>();
  const head: AcpmuxRow[] = [
    user(1_000),
    { id: "answer-1", version: 1, at: 2_000, kind: "assistant", text: "First." },
    { id: "user-2", version: 1, at: 4_000, kind: "user", text: "Two" },
    { id: "answer-2", version: 1, at: 5_000, kind: "assistant", text: "Second." },
    { id: "user-3", version: 1, at: 50_000, kind: "user", text: "resume" },
    { id: "tool", version: 1, at: 103_000, kind: "activity", items: [] },
    { id: "answer", version: 1, at: 105_000, kind: "assistant", text: "done" },
  ];
  const previous = turnViewFrom(head, folds, options);
  expect(previous.rows.find((row) => row.kind === THINKING)?.at).toBe(100_000);
  // A quiet background turn lands at the end: the folds change, so every turn draws again.
  const next: AcpmuxRow[] = [
    ...head,
    {
      id: "backgroundTurn-bg",
      version: 1,
      at: 106_000,
      kind: BACKGROUND_TURN,
      background: { id: "bg", trigger: "scheduled", running: false, quiet: true },
    },
  ];
  const shown = turnViewFrom(next, folds, options, previous);
  expect(shown.rows.find((row) => row.kind === THINKING)?.at).toBe(100_000);
});

test("a new turn start alone draws the live turn again", () => {
  const rows: AcpmuxRow[] = [user(1_000), { id: "typing", version: 1, at: 100_000, kind: "typing" }];
  const previous = turnViewFrom(rows, new Set(), { now: 200_000, working: true, turnStartedAtMs: 100_000 });
  const shown = turnViewFrom(rows, new Set(), { now: 200_000, working: true, turnStartedAtMs: 150_000 }, previous);
  expect(shown.rows.find((row) => row.kind === THINKING)?.at).toBe(150_000);
});

// Leo, 2026-11-12: "the working for whatever seconds, it just still doesn't load properly". A page
// that starts inside a turn holds its work but not its prompt: the time since the first row held is
// not the turn's time, so the fold names no time rather than a short one.
test("a turn whose prompt is in an older page draws no made-up Worked for time", () => {
  const shown = turnView(
    [
      { id: "tool", version: 1, at: 90_000, kind: "activity", items: [], toolCount: 2 },
      { id: "answer", version: 1, at: 95_000, kind: "assistant", text: "done" },
      { id: "summary", version: 1, at: 96_000, kind: "turnSummary", status: "completed", toolCount: 2 },
    ],
    new Set(),
    { now: 100_000, working: false },
  );
  const worked = shown.find((row) => row.kind === WORKED);
  if (worked) expect(worked.durationMs).toBeUndefined();
});

test("a turn with its prompt held keeps its Worked for time", () => {
  const shown = turnView(
    [
      user(1_000),
      { id: "tool", version: 1, at: 90_000, kind: "activity", items: [], toolCount: 2 },
      { id: "answer", version: 1, at: 95_000, kind: "assistant", text: "done" },
      { id: "summary", version: 1, at: 96_000, kind: "turnSummary", status: "completed", toolCount: 2 },
    ],
    new Set(),
    { now: 100_000, working: false },
  );
  expect(shown.find((row) => row.kind === WORKED)?.durationMs).toBe(95_000);
});
