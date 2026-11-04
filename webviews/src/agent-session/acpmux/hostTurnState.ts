// Whether acpmux runs a turn of a chat, read from its session summary: `turn`, the turn acpmux
// holds open (protocol/session.rs `TurnSummary`, null between turns), and `status`.
//
// The pane folds a turn open from its records (`user_message`, `turn_started`) and closed from its
// end (`turn_end`, `turn_result`). That fold alone kept Stop and the typing dots on when a turn's
// end never reached the pane, and kept them off for a turn acpmux runs on without a new start
// record (a restart that adopts its running host, hub/hosts.rs). acpmux clears `turn` before it
// logs a turn's end and sets it before its start, and builds each `session_changed` summary when it
// sends it, after the record it follows: the summary is never older than the records the pane has
// folded, so it settles the fold (https://github.com/manaflow-ai/cmux/issues/32727).

type Summary = Record<string, any> | undefined;

/// The turn acpmux holds open, as its summary says: a turn object, null between turns, undefined
/// when the summary does not say (an older acpmux or peer, a summary not read yet).
export function hostTurn(summary: Summary): { turnId?: string } | null | undefined {
  if (!summary || !("turn" in summary)) return undefined;
  const turn = summary.turn;
  if (turn === null) return null;
  if (typeof turn !== "object") return undefined;
  return { turnId: typeof turn.turnId === "string" && turn.turnId ? turn.turnId : undefined };
}

/// What the summary says of the pane's open turn: `ended` when acpmux runs none, `runs` when it
/// runs one, `unknown` when the summary cannot tell. A watched chat's turns are the other app's,
/// shown from its transcript (hub/watch.rs): acpmux holds none of them, so its summary never tells.
export function hostTurnState(summary: Summary): "runs" | "ended" | "unknown" {
  if (!summary || summary.watching) return "unknown";
  const turn = hostTurn(summary);
  if (turn === undefined) return "unknown";
  if (turn !== null) return "runs";
  // A paused queue's "running" with no turn is from before its turn failed (queuePausedState.test.ts,
  // direct.ts `staleRun`): acpmux runs none.
  if (summary.status === "running" && summary.queuePaused !== true) return "runs";
  return "ended";
}
