// A turn's "Worked for" held open at its end over work the reader had in view (useTurnActions.ts
// `heldWorked`, cmux#24569) closes on their click, while they are still scrolled up. The click's pass
// saw the work it hides go out of view and held the fold open again: the click did nothing until the
// view followed the latest row (Lucas, 2026-11-24).
import { afterAll, beforeAll, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  letGoHeldWorked,
  turnRowsShownFrom,
  type TurnRowsShownDeps,
} from "../src/agent-session/acpmux/pane/useTurnActions";

const liveTurnArmsBefore = globalThis.cmuxExperiments;
beforeAll(() => {
  globalThis.cmuxExperiments = { ...liveTurnArmsBefore, "live-turn-work": "runs" };
});
afterAll(() => {
  globalThis.cmuxExperiments = liveTurnArmsBefore;
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const tool = (id: string) =>
  row(id, "activity", {
    items: [{ kind: "tool", text: "", tool: { id, title: id, kind: "read", status: "completed" } }],
  });
const ended = [
  row("u", "user", { text: "Fix the cap" }),
  row("n1", "assistant", { text: "Checking n1: it retries on every error." }),
  tool("t1"),
  row("answer", "assistant", { text: "Every retry loop now shares one capped backoff." }),
  row("end", "turnSummary", { status: "completed", durationMs: 9_000 }),
];
const ids = (rows: readonly AcpmuxRow[]) => rows.map((each) => each.id);

/// A pane's refs for `turnRowsShownFrom`, the reader scrolled to `view.inView` (null: following).
function pane() {
  const view: { inView: readonly string[] | null } = { inView: null };
  const heldWorked = { current: { keys: new Set<string>() } as TurnRowsShownDeps["heldWorked"]["current"] };
  const lastTurns: TurnRowsShownDeps["lastTurns"] = { current: undefined };
  const foldsSeen: TurnRowsShownDeps["foldsSeen"] = { current: {} };
  const folds = new Set<string>();
  let release = 0;
  const shown = (sourceRows: AcpmuxRow[], isWorking: boolean) =>
    ids(
      turnRowsShownFrom({
        chatPresentation: "transcript" as TurnRowsShownDeps["chatPresentation"],
        childRows: undefined,
        sourceRows,
        panelAsks: new Set(),
        started: [],
        startedCache: { current: new Map() },
        doneLines: { current: new Map() },
        workflowLabsEnabled: false,
        lastTurns,
        shownSessionId: "s",
        heldCalls: { current: { session: "s", keys: new Set() } },
        callRelease: (release += 1),
        transcriptInView: { current: () => view.inView },
        heldRuns: { current: { session: "s", keys: new Set() } },
        heldWorked,
        heldWorkedClosing: { current: false },
        snapshot: { isWorking, canLoadNewer: false, clockOffsetMs: 0, turnStartedAtMs: undefined, waitingSteers: [] },
        messageBreaks: [],
        supersededReplyIds: undefined,
        foldsSeen,
        folds,
        heldFolds: { current: { session: "s", keys: new Set() } },
        chatShellRuns: [],
      }),
    );
  /// App.tsx `toggleActivity` on a held Worked for.
  const click = (id: string) => {
    const letGo = letGoHeldWorked(heldWorked.current, id);
    expect(letGo).toBeDefined();
    heldWorked.current = letGo!;
  };
  return { view, heldWorked, shown, click };
}

test("a Worked for held open at the turn's end closes on the reader's click, still scrolled up", () => {
  const { view, heldWorked, shown, click } = pane();
  // The turn runs with the reader at the latest row: its work is drawn.
  expect(shown(ended.slice(0, -1), true)).toContain("t1");
  // They scroll up onto the run "t1"; the turn ends: its Worked for stays open over what they read.
  view.inView = ["t1"];
  expect(shown(ended, false)).toContain("t1");
  expect([...heldWorked.current.keys]).toEqual(["worked-u"]);
  // Their click lets go of the hold and shapes the rows again, the view still scrolled up: the
  // fold closes, and stays closed.
  click("worked-u");
  expect(shown(ended, false)).not.toContain("t1");
  expect([...heldWorked.current.keys]).toEqual([]);
  // A later update while still scrolled up does not open it again.
  expect(shown(ended, false)).not.toContain("t1");
});

test("the click lets go of its own fold only: a turn that ends in the same pass still holds", () => {
  const next = [
    row("v", "user", { text: "And the jitter" }),
    row("m1", "assistant", { text: "Checking m1: the jitter is fixed." }),
    tool("t2"),
    row("answer-v", "assistant", { text: "Jitter added to the shared backoff." }),
    row("end-v", "turnSummary", { status: "completed", durationMs: 4_000 }),
  ];
  const { view, heldWorked, shown, click } = pane();
  shown(ended.slice(0, -1), true);
  view.inView = ["t1"];
  shown(ended, false);
  expect([...heldWorked.current.keys]).toEqual(["worked-u"]);
  // The next turn runs; the reader reads its work and the first turn's held work together.
  view.inView = ["t1", "t2"];
  expect(shown([...ended, ...next.slice(0, -1)], true)).toContain("t2");
  // They close the first turn's Worked for in the pass where the second turn ends.
  click("worked-u");
  const rows = shown([...ended, ...next], false);
  expect(rows).not.toContain("t1");
  expect(rows).toContain("t2");
  expect([...heldWorked.current.keys]).toEqual(["worked-v"]);
});
