// The live line holds each status for at least a dwell before the next replaces it (Leo, 2026-11-24: "the
// sending messages in rapid succession is really bad looking. it's just your tool call/thinking
// glimmer text rapidly flickering up with very bad/nonexistent fade-in fade-out. it needs to be more
// graceful, the overall animation of that thinking to tool call switching back and forth"). A burst
// of thirty calls in two seconds, each one a Thinking and a call, rolled the line thirty times, each
// roll cut off by the next before it ended. Now a status shown for less than LIVE_DWELL_MS keeps the
// line until its dwell ends, and only the newest status waiting then rolls in: the burst reads as a
// few whole rolls. A change after a quiet stretch still shows in the same frame, so a lone call never
// waits. Updates to the shown status itself (its words turning "Ran", its time) pass straight
// through. Reduce Motion keeps the dwell: words swapped thirty times in two seconds flicker with no
// motion too. Gallery: agent-pane.live-line-burst (LiveLineBurst.gallery.ts).
import { createContext, useEffect, useState } from "react";
import type { AcpmuxRow } from "../model";

/// The least time a status stays on the live line: two of the roll's own step (`--agent-motion-in`,
/// 120 ms) plus a reading beat, so every roll ends and rests before the next starts.
export const LIVE_DWELL_MS = 400;

/// The dwell the transcript's live line uses; 0 shows every change at once (the gallery's before).
export const LiveDwellContext = createContext(LIVE_DWELL_MS);

/// `value`, whose `key` changes at most once per `dwellMs`: a new key inside the dwell waits for its
/// end, and only the newest waiting value then shows. A new value under the shown key shows at once.
/// `value` must keep its identity while it is unchanged (a row, not an object made each render).
export function useKeyedDwell<T>(key: string, value: T, dwellMs: number, clock: () => number = Date.now): T {
  const [shown, setShown] = useState(() => ({ key, value, at: clock() }));
  let held = key !== shown.key;
  if (held && (dwellMs <= 0 || clock() - shown.at >= dwellMs)) {
    // Past the dwell: the new key shows in this render, never a frame late.
    setShown({ key, value, at: clock() });
    held = false;
  } else if (!held && !Object.is(value, shown.value)) {
    // The shown status updated: keep its newest value, which a held change goes on drawing.
    setShown({ key, value, at: shown.at });
  }
  useEffect(() => {
    if (!held) return;
    const timer = setTimeout(() => setShown({ key, value, at: clock() }), Math.max(0, shown.at + dwellMs - clock()));
    return () => clearTimeout(timer);
  }, [held, key, value, shown.at, dwellMs, clock]);
  return held ? shown.value : value;
}

/// What the live line names: a call by its id (its words may change in place), else its state.
export function liveStatusKey(row: AcpmuxRow): string {
  if (row.doing !== undefined) return `call\u0000${row.doingCall ?? row.doing}\u0000${row.doingSendTo ?? ""}`;
  return `state\u0000${row.liveState ?? ""}`;
}

/// `row` drawn with the status `shown` holds: its call and state, with everything else (the turn's
/// time, what it heard, a retry, a wait) from the newest row.
export function withLiveStatus(row: AcpmuxRow, shown: AcpmuxRow): AcpmuxRow {
  if (shown === row) return row;
  return {
    ...row,
    doing: shown.doing,
    doingAt: shown.doingAt,
    doingShell: shown.doingShell,
    doingSendTo: shown.doingSendTo,
    doingSendSession: shown.doingSendSession,
    doingDraft: shown.doingDraft,
    doingDone: shown.doingDone,
    doingCall: shown.doingCall,
    doingForMs: shown.doingForMs,
    doingCommand: shown.doingCommand,
    liveState: shown.liveState,
    liveAgents: shown.liveAgents,
    liveCompaction: shown.liveCompaction,
  };
}
