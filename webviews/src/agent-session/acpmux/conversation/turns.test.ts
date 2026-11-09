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

// Leo, 2026-11-09: "we can be a bit more optimistic with, like, the displaying of the thinking ...
// I only started seeing your thinking bit, like, seven seconds in". A running turn's thought draws
// from its first words, streaming in its live viewport, not only once the next step ends it.
test("a running turn draws its thought from its first line, then keeps it in the run", () => {
  const text = "Looking for every retry loop: the fetch client, the socket reconnect";
  const thought = { kind: "thought", text, startedAt: 2_000, endedAt: 2_400 };
  const streaming = turnView(
    [user(1_000), { id: "act", version: 1, at: 2_000, kind: "activity", items: [thought], streaming: true }],
    new Set(),
    { now: 3_000, working: true },
  );
  const run = streaming.find((row) => row.id === "act");
  expect(run?.items?.map((item) => item.text)).toEqual([text]);
  expect(run?.live).toBe(true);
  // Its run is the running turn's: the thought keeps the shape it streamed in (ThoughtRow `held`).
  expect(run?.liveRun).toBe(true);
  expect(streaming.at(-1)?.kind).toBe(THINKING);
  // A call after it ends it: it stays in the run, no longer live; the call in flight is the line's.
  const call = {
    kind: "tool",
    text: "",
    tool: { id: "t1", title: "rg retry", kind: "execute", status: "in_progress" },
  };
  const working = turnView(
    [user(1_000), { id: "act", version: 2, at: 2_000, kind: "activity", items: [thought, call] }],
    new Set(),
    { now: 3_000, working: true },
  );
  const after = working.find((row) => row.id === "act");
  expect(after?.items?.map((item) => item.kind)).toEqual(["thought"]);
  expect(after?.live).toBeUndefined();
  expect(after?.liveRun).toBe(true);
  // A thought still shorter than a quiet one draws nothing yet: if it ended that short it would draw
  // no row (thoughts.ts `isQuietThought`), so it would show and then leave.
  const short = turnView(
    [
      user(1_000),
      { id: "act", version: 1, at: 2_000, kind: "activity", items: [{ ...thought, text: "Three loops." }] },
    ],
    new Set(),
    { now: 3_000, working: true },
  );
  expect(short.some((row) => row.id === "act")).toBe(false);
  // One that has run a second draws now, as it does once the turn ends or the chat reloads: live and
  // restored agree (Leo, 2026-11-09: "now i see it", after a reload).
  const slow = turnView(
    [
      user(1_000),
      {
        id: "act",
        version: 1,
        at: 2_000,
        kind: "activity",
        items: [{ ...thought, text: "Three loops.", endedAt: 3_200 }],
      },
    ],
    new Set(),
    { now: 3_300, working: true },
  );
  expect(slow.find((row) => row.id === "act")?.items?.map((item) => item.text)).toEqual(["Three loops."]);
});

// Leo, 2026-11-09, on a coordinator chat: "and your thinking disappeared?" when another agent's
// message (acpmux's inbox notice, sent into the running turn as a steer) came in under a streaming
// thought. Guard: the shaping keeps the thought in its run whether the notice still waits (it
// leaves for the group of waiting messages) or has landed, and a view built on the previous one
// draws what a fresh one does (a reload).
test("an inbox notice that lands mid-thought leaves the thought in its run", () => {
  const text = "Checking whether the lane's PR merged and whether the nightly picked it up yet";
  const thought = { kind: "thought", text, startedAt: 2_000, endedAt: 4_000 };
  const act: AcpmuxRow = { id: "act", version: 1, at: 2_000, kind: "activity", items: [thought], streaming: true };
  const notice = (steer: "waiting" | "landed"): AcpmuxRow => ({
    id: "inbox",
    version: steer === "waiting" ? 1 : 2,
    at: 5_000,
    kind: "user",
    text: "[inbox] New messages from other agents in 1 thread.",
    untyped: true,
    steer,
    incoming: {
      kind: "message",
      message: { name: "lane-10", sessionId: "s10", text: "cmuxterm-hq#8471 merged", raw: "" },
    },
  });
  const options = { now: 6_000, working: true };
  const before = turnViewFrom([user(1_000), act], new Set(), options);
  expect(before.rows.find((row) => row.id === "act")?.live).toBe(true);
  for (const steer of ["waiting", "landed"] as const) {
    const rows = [user(1_000), act, notice(steer)];
    const built = turnViewFrom(rows, new Set(), options, before);
    const fresh = turnViewFrom(rows, new Set(), options);
    const run = built.rows.find((row) => row.id === "act");
    expect(run?.items?.map((item) => item.text)).toEqual([text]);
    expect(run?.liveRun).toBe(true);
    expect(built.rows.map((row) => `${row.id}:${row.version}`)).toEqual(
      fresh.rows.map((row) => `${row.id}:${row.version}`),
    );
  }
});
