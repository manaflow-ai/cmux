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

// Leo, 2026-11-09: "we can be a bit more optimistic with, like, the displaying of the thinking ...
// I only started seeing your thinking bit, like, seven seconds in". A running turn's thought draws
// from its first words, as its folded line, not only once the next step ends it.
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
  // Drawn as its folded line from the start (ThoughtRow without `streaming`): nothing resizes when it ends.
  expect(run?.live).toBeUndefined();
  expect(streaming.at(-1)?.kind).toBe(THINKING);
  // A call after it ends it: it stays in the run, as drawn; the call in flight is the line's.
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
  // A thought that opens its run waits out its first 100 ms of chunks, so its row never lands in the
  // frame its run and the turn's Working line do (turn-transition-jumps burst-thought).
  const first = turnView(
    [user(1_000), { id: "act", version: 1, at: 2_000, kind: "activity", items: [{ ...thought, endedAt: 2_040 }] }],
    new Set(),
    { now: 3_000, working: true },
  );
  expect(first.some((row) => row.id === "act")).toBe(false);
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
  expect(before.rows.find((row) => row.id === "act")?.items?.map((item) => item.text)).toEqual([text]);
  for (const steer of ["waiting", "landed"] as const) {
    const rows = [user(1_000), act, notice(steer)];
    const built = turnViewFrom(rows, new Set(), options, before);
    const fresh = turnViewFrom(rows, new Set(), options);
    // A landed notice beside the run folds with it under one message-run line (messageRuns.ts), as
    // any finished run of the turn and a received message do: the thought is in that line's rows,
    // and opening the line draws it.
    const line = built.rows.find((row) => row.messageRun?.rows.includes("act"));
    const opened = line ? turnViewFrom(rows, new Set([line.id]), options, built) : built;
    const run = opened.rows.find((row) => row.id === "act");
    expect(run?.items?.map((item) => item.text)).toEqual([text]);
    expect(built.rows.map((row) => `${row.id}:${row.version}`)).toEqual(
      fresh.rows.map((row) => `${row.id}:${row.version}`),
    );
  }
});

// Review of #39781 (Codex, F2): a Stop that ends a streaming thought, its turn's fold held open,
// redraws the run. The run that shows its thought and the ended turn's open fold of the same row
// draw otherwise, so their versions differ (rows/ToolActivityRow.tsx compares versions only).
test("a streaming thought's run and the stopped turn's open fold of it have their own versions", () => {
  const text = "Looking for every retry loop: the fetch client, the socket reconnect";
  const act: AcpmuxRow = {
    id: "act",
    version: 3,
    at: 2_000,
    kind: "activity",
    items: [{ kind: "thought", text, startedAt: 2_000, endedAt: 2_400 }],
    streaming: true,
  };
  const live = turnView([user(1_000), act], new Set(), { now: 3_000, working: true }).find((row) => row.id === "act");
  expect(live?.items?.map((item) => item.text)).toEqual([text]);
  const stopped = [
    user(1_000),
    act,
    { id: "summary", version: 1, at: 3_000, kind: "turnSummary", status: "cancelled", durationMs: 2_000 } as AcpmuxRow,
  ];
  const options = { now: 4_000, working: false, turnStartedAtMs: 1_000 };
  const fold = turnView(stopped, new Set(), options).find((row) => row.kind === WORKED);
  const open = turnView(stopped, new Set(fold ? [fold.id] : []), options).find((row) => row.id === "act");
  expect(open).toBeDefined();
  expect(open!.version).not.toBe(live!.version);
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

// A run that asks for an edit's permission is still the running turn's: its thought and the change
// it asks about stay in sight, unfolded, while the turn waits. (A running turn's thought draws as the
// one line it folds to since #39781, so no run needs the old live shape, `liveRun`, any more.)
test("a running turn's run waiting on an edit's permission keeps its thought and change in sight", () => {
  const thought = {
    kind: "thought",
    text: "The retry loop lives in the fetch client; changing its backoff",
    startedAt: 2_000,
    endedAt: 2_400,
  };
  const edit = {
    kind: "tool",
    text: "",
    tool: { id: "e1", title: "Edit fetch.ts", kind: "edit", status: "pending", locations: [{ path: "fetch.ts" }] },
  };
  const shown = turnView(
    [user(1_000), { id: "act", version: 1, at: 2_000, kind: "activity", items: [thought, edit] }],
    new Set(),
    { now: 3_000, working: true },
  );
  const run = shown.find((row) => row.id === "act");
  expect(run?.items?.map((item) => item.kind)).toEqual(["thought", "tool"]);
  expect(run?.foldRun).toBe(false);
});
