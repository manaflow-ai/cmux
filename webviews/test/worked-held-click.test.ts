// A turn's "Worked for" held open at its end over work the reader had in view (useTurnActions.ts
// `heldWorked`, cmux#24569) closes on their click, while they are still scrolled up. The click's pass
// saw the work it hides go out of view and held the fold open again: the click did nothing until the
// view followed the latest row (Lucas, 2026-11-24).
import { afterAll, beforeAll, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnRowsShownFrom, type TurnRowsShownDeps } from "../src/agent-session/acpmux/pane/useTurnActions";

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

test("a Worked for held open at the turn's end closes on the reader's click, still scrolled up", () => {
  let inView: readonly string[] | null = null;
  const heldWorked = { current: { keys: new Set<string>() } as TurnRowsShownDeps["heldWorked"]["current"] };
  const deps = (sourceRows: AcpmuxRow[], isWorking: boolean, callRelease: number): TurnRowsShownDeps => ({
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
    callRelease,
    transcriptInView: { current: () => inView },
    heldRuns: { current: { session: "s", keys: new Set() } },
    heldWorked,
    heldWorkedClosing: { current: false },
    snapshot: { isWorking, canLoadNewer: false, clockOffsetMs: 0, turnStartedAtMs: undefined, waitingSteers: [] },
    sessionStatus: false,
    messageBreaks: [],
    supersededReplyIds: undefined,
    foldsSeen,
    folds,
    heldFolds: { current: { session: "s", keys: new Set() } },
    chatShellRuns: [],
  });
  const lastTurns: TurnRowsShownDeps["lastTurns"] = { current: undefined };
  const foldsSeen: TurnRowsShownDeps["foldsSeen"] = { current: {} };
  const folds = new Set<string>();

  // The turn runs with the reader at the latest row: its work is drawn.
  expect(ids(turnRowsShownFrom(deps(ended.slice(0, -1), true, 0)))).toContain("t1");
  // They scroll up onto the run "t1"; the turn ends: its Worked for stays open over what they read.
  inView = ["t1"];
  expect(ids(turnRowsShownFrom(deps(ended, false, 0)))).toContain("t1");
  expect([...heldWorked.current.keys]).toEqual(["worked-u"]);

  // Their click on it (App.tsx `toggleActivity`) lets go of the hold and shapes the rows again,
  // the view still scrolled up: the fold closes, and stays closed.
  const keys = new Set(heldWorked.current.keys);
  keys.delete("worked-u");
  heldWorked.current = { ...heldWorked.current, keys, letGo: true };
  expect(ids(turnRowsShownFrom(deps(ended, false, 1)))).not.toContain("t1");
  expect([...heldWorked.current.keys]).toEqual([]);
  // A later update while still scrolled up does not open it again.
  expect(ids(turnRowsShownFrom(deps(ended, false, 2)))).not.toContain("t1");
});
