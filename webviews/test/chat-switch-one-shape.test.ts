// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// The render that first shows another chat runs with the folds of the chat it left: AcpmuxPane puts
// the shown chat's own folds in `expanded` later in that render, and React renders it again. Shaped
// in that first pass, every turn was shaped under folds the kept turns were not shaped with, and that
// pass's turns, kept as the last ones, made the pass React keeps shape every turn again (settled-page
// bench, chat_switch: two whole shapes a switch, a switch back included). These hold a switch to the
// turns kept for the chat (a switch back's, or those shaped ahead, pane/useTurnActions.ts `shapeAhead`).
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnRowsShownFrom, type TurnRowsShownDeps } from "../src/agent-session/acpmux/pane/useTurnActions";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
/** `count` finished turns of chat `name`. */
const chat = (name: string, count: number) =>
  Array.from({ length: count }, (_, turn) => [
    row(`${name}-u${turn}`, "user", { text: `Step ${turn}` }),
    row(`${name}-a${turn}`, "assistant", { text: `Step ${turn} done.` }),
    row(`${name}-e${turn}`, "turnSummary", { status: "completed", durationMs: 4_000 }),
  ]).flat();

/** A snapshot's lists keep their identity across renders, as the client keeps them. */
const NO_BREAKS: TurnRowsShownDeps["messageBreaks"] = [];
const NO_STEERS: TurnRowsShownDeps["snapshot"]["waitingSteers"] = [];

/** One pane's refs across chats, as AcpmuxPane keeps them. */
function pane() {
  const lastTurns: TurnRowsShownDeps["lastTurns"] = { current: undefined };
  const pastTurns: NonNullable<TurnRowsShownDeps["pastTurns"]> = { current: new Map() };
  const foldsSeen: TurnRowsShownDeps["foldsSeen"] = { current: {} };
  const heldCalls: TurnRowsShownDeps["heldCalls"] = { current: { keys: new Set() } };
  const heldRuns: TurnRowsShownDeps["heldRuns"] = { current: { keys: new Set() } };
  const heldWorked = { current: { keys: new Set<string>() } as TurnRowsShownDeps["heldWorked"]["current"] };
  const heldFolds: TurnRowsShownDeps["heldFolds"] = { current: { keys: new Set() } };
  const shown = (shownSessionId: string, sourceRows: AcpmuxRow[], folds: Set<string>) =>
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
      pastTurns,
      shownSessionId,
      heldCalls,
      callRelease: 0,
      transcriptInView: { current: () => null },
      heldRuns,
      heldWorked,
      heldWorkedClosing: { current: false },
      snapshot: {
        isWorking: false,
        canLoadNewer: false,
        clockOffsetMs: 0,
        turnStartedAtMs: undefined,
        waitingSteers: NO_STEERS,
      },
      messageBreaks: NO_BREAKS,
      supersededReplyIds: undefined,
      foldsSeen,
      folds,
      heldFolds,
      chatShellRuns: [],
    });
  return { lastTurns, pastTurns, shown };
}

test("a switch back shapes the chat once, from the turns it kept, not twice from none", () => {
  const { lastTurns, pastTurns, shown } = pane();
  const [rowsA, rowsB] = [chat("a", 40), chat("b", 40)];
  const [foldsA, foldsB] = [new Set<string>(), new Set<string>()];
  shown("b", rowsB, foldsB);
  const keptB = lastTurns.current!.turns;
  shown("a", rowsA, foldsA);
  const shownA = lastTurns.current;
  expect(pastTurns.current.get("b")?.turns).toBe(keptB);
  // The pass React throws away: chat B with chat A's folds. It keeps nothing from it.
  shown("b", rowsB, foldsA);
  expect(lastTurns.current).toBe(shownA);
  expect(pastTurns.current.get("b")?.turns).toBe(keptB);
  // The pass React keeps, with B's own folds, reuses the turns B kept.
  const drawn = shown("b", rowsB, foldsB);
  expect(lastTurns.current!.sessionId).toBe("b");
  // Nothing in B changed while it was away: turnViewFrom hands back the very turns B kept, shaping none.
  expect(lastTurns.current!.turns).toBe(keptB);
  expect(drawn.map((each) => each.id)).toContain("b-a39");
});

test("the first show of a chat nothing was kept for shapes it in the first pass, as before", () => {
  const { lastTurns, shown } = pane();
  const [rowsA, rowsC] = [chat("a", 3), chat("c", 3)];
  const [foldsA, foldsC] = [new Set<string>(), new Set<string>()];
  shown("a", rowsA, foldsA);
  const first = shown("c", rowsC, foldsA);
  expect(first.map((each) => each.id)).toContain("c-a2");
  expect(lastTurns.current!.sessionId).toBe("c");
  expect(shown("c", rowsC, foldsC).map((each) => each.id)).toContain("c-a2");
});
