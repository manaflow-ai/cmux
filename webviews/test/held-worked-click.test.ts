// A turn that ends while the reader is scrolled up into its work keeps its "Worked for" open
// (App.tsx `heldWorked`, conversation/turnEndHold.ts). A click on that fold closes it, and it stays
// closed: the rows the click folds away are in view, and the hold must not take them for a turn's
// end and open the fold again (Lucas, 2026-11-24: "it is not letting me click on Worked for to
// close/collapse").
import { afterAll, beforeAll, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { Folds } from "../src/agent-session/acpmux/conversation/viewFolds";
import {
  closeHeldWorked,
  turnRowsShownFrom,
  type HeldWorked,
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
  tool("t2"),
  row("answer", "assistant", { text: "Every retry loop now shares one capped backoff. ".repeat(4) }),
  row("end", "turnSummary", { status: "completed", durationMs: 9_000 }),
];
const ids = (rows: readonly AcpmuxRow[]) => rows.map((each) => each.id);

/// The pane's refs and memo inputs, as AcpmuxPane holds them across renders.
function pane() {
  const folds: Folds = new Set<string>();
  const heldWorked = { current: { keys: new Set<string>() } as HeldWorked };
  let inView: readonly string[] | null = null;
  let release = 0;
  const deps = (rows: AcpmuxRow[], working: boolean): TurnRowsShownDeps => ({
    chatPresentation: "transcript",
    childRows: undefined,
    sourceRows: rows,
    panelAsks: new Set(),
    started: [],
    startedCache: { current: new Map() },
    doneLines: { current: new Map() },
    workflowLabsEnabled: false,
    lastTurns,
    shownSessionId: "s",
    heldCalls,
    callRelease: release,
    transcriptInView: { current: () => inView },
    heldRuns,
    heldWorked,
    heldWorkedClosing: { current: false },
    snapshot: { isWorking: working },
    sessionStatus: false,
    messageBreaks: [],
    supersededReplyIds: undefined,
    foldsSeen,
    folds,
    heldFolds,
    chatShellRuns: [],
  });
  const lastTurns: TurnRowsShownDeps["lastTurns"] = { current: undefined };
  const heldCalls = { current: { keys: new Set<string>() } };
  const heldRuns = { current: { keys: new Set<string>() } };
  const heldFolds = { current: { keys: new Set<string>() } };
  const foldsSeen: TurnRowsShownDeps["foldsSeen"] = { current: {} };
  return {
    heldWorked,
    scrolledTo: (ids: readonly string[] | null) => (inView = ids),
    render: (rows: AcpmuxRow[], working: boolean) => turnRowsShownFrom(deps(rows, working)),
    /// toggleActivity's branch for a held Worked for, then the render its `releaseCalls` asks for.
    click: (id: string) => {
      const next = closeHeldWorked(heldWorked.current, id);
      if (next) heldWorked.current = next;
      release += 1;
    },
  };
}

test("a Worked for held open over the work in view closes on one click, and stays closed", () => {
  const view = pane();
  // The turn runs: every row is drawn. The reader scrolls up to the call "t1".
  expect(ids(view.render(ended.slice(0, -1), true))).toContain("t1");
  view.scrolledTo(["t1"]);
  expect(ids(view.render(ended.slice(0, -1), true))).toContain("t1");
  // The turn ends: its Worked for stays open over "t1" while the reader is scrolled up.
  expect(ids(view.render(ended, false))).toContain("t1");
  expect([...view.heldWorked.current.keys]).toEqual(["worked-u"]);
  // The reader clicks it, still scrolled up with "t1" in view: it closes.
  view.click("worked-u");
  const closed = view.render(ended, false);
  expect(ids(closed)).not.toContain("t1");
  expect([...view.heldWorked.current.keys]).toEqual([]);
  // A later render while they stay there keeps it closed.
  expect(ids(view.render(ended, false))).not.toContain("t1");
  // Back at the latest row, the click is forgotten with the hold.
  view.scrolledTo(null);
  view.render(ended, false);
  expect(view.heldWorked.current.closed).toBeUndefined();
});

test("a turn that runs again after the click holds its Worked for afresh at its end", () => {
  const view = pane();
  view.scrolledTo(["t1"]);
  view.render(ended.slice(0, -1), true);
  view.render(ended, false);
  view.click("worked-u");
  expect(ids(view.render(ended, false))).not.toContain("t1");
  // A steer continues the turn under the same key: the reader's close of the last end is forgotten.
  const steer = row("steer", "user", { text: "Also cap the jitter", continues: true });
  const continued = [...ended.slice(0, -1), steer, tool("t3")];
  view.render(continued, true);
  expect(view.heldWorked.current.closed).toBeUndefined();
});
