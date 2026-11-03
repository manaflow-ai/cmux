import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN } from "./backgroundTurns";
import { THINKING, WORKING, turnView, turnViewFrom } from "./turns";

const user = (at: number): AcpmuxRow => ({ id: "user", version: 1, at, kind: "user", text: "resume" });

test("a resumed live turn counts from turn_started instead of its old prompt", () => {
  const rows: AcpmuxRow[] = [
    user(1_000),
    // direct.ts carries this timestamp from the live turn_started event in the snapshot.
    { id: "typing", version: 1, at: 100_000, kind: "typing" },
  ];
  const shown = turnView(rows, new Set(), {
    now: 200_000,
    working: true,
    liveRuns: true,
    lineBelow: true,
    turnStartedAtMs: 100_000,
  });
  expect(shown.find((row) => row.kind === THINKING)?.at).toBe(100_000);
});

test("a completed turn has no live timer row", () => {
  const shown = turnView(
    [
      user(1_000),
      { id: "answer", version: 1, at: 5_000, kind: "assistant", text: "done" },
      { id: "summary", version: 1, at: 6_000, kind: "turnSummary", status: "completed", durationMs: 5_000 },
    ],
    new Set(),
    { now: 10_000, working: false },
  );
  expect(shown.some((row) => row.kind === THINKING || row.kind === WORKING)).toBe(false);
});

test("the line above a completed answer keeps the live turn start", () => {
  const shown = turnView(
    [
      user(1_000),
      { id: "tool", version: 1, at: 103_000, kind: "activity", items: [] },
      { id: "answer", version: 1, at: 105_000, kind: "assistant", text: "done" },
    ],
    new Set(),
    { now: 110_000, working: true, turnStartedAtMs: 100_000, lineBelow: false },
  );
  expect(shown.find((row) => row.kind === WORKING)?.durationMs).toBe(5_000);
});

test("a rebuild for a changed background fold keeps the live turn start", () => {
  const options = { now: 110_000, working: true, turnStartedAtMs: 100_000, lineBelow: false };
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
  expect(previous.rows.find((row) => row.kind === WORKING)?.at).toBe(100_000);
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
  expect(shown.rows.find((row) => row.kind === WORKING)?.at).toBe(100_000);
});
