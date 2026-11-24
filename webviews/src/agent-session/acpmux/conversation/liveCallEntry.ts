// The live line names a call only once it has run a moment (Leo, 2026-11-24: "the sending messages
// in rapid succession is really bad looking. it's just your tool call/thinking glimmer text rapidly
// flickering up with very bad/nonexistent fade-in fade-out. it needs to be more graceful, the overall
// animation of that thinking to tool call switching back and forth"). A burst of thirty quick calls
// in two seconds, each a call and then Thinking, rolled the line thirty times, every roll cut off by
// the next. Now a new call waits LIVE_CALL_ENTRY_MS before the line names it: one done before then
// never shows on the line (its row lands in the transcript as every call's does), so through a burst
// the line stays on Thinking, its shimmer running on, and a call that runs longer rolls in whole.
// Everything else changes at once: a finished call leaves the line in the frame its row lands (held,
// its name would stand twice, on the line and on its row; thinking-tool-swap-frames.test.ts), and
// Writing, a wait on subagents or a compaction show as they start. The shown status's own updates
// (its words turning "Ran", its time) pass straight through. Reduce Motion keeps the rule: words
// swapped thirty times in two seconds flicker with no motion too. Gallery: agent-pane.live-line-burst.
import { createContext, useEffect, useState } from "react";
import type { AcpmuxRow } from "../model";

/// How long a call runs before the live line names it: about two of the roll's own steps, longer than
/// most reads and searches take, short enough that a command's name comes while it plainly runs.
export const LIVE_CALL_ENTRY_MS = 250;

/// The entry wait the transcript's live line uses; 0 names every call at once (the gallery's before).
export const LiveCallEntryContext = createContext(LIVE_CALL_ENTRY_MS);

/// What the live line names: a call by its id (its words may change in place), else its state.
export function liveStatusKey(row: AcpmuxRow): string {
  if (row.doing !== undefined) return `call\u0000${row.doingCall ?? row.doing}\u0000${row.doingSendTo ?? ""}`;
  return `state\u0000${row.liveState ?? ""}`;
}

const isCall = (key: string) => key.startsWith("call\u0000");

/// The row the live line draws: `latest`, except that a new call shows only once it has been the
/// newest for `entryMs`; until then the line keeps the status it shows. `latest` keeps its identity
/// while unchanged (a transcript row).
export function useLiveStatus(latest: AcpmuxRow, entryMs: number, clock: () => number = Date.now): AcpmuxRow {
  const key = liveStatusKey(latest);
  // The status drawn, and when the newest key was first seen (a call's wait runs from it).
  const [shown, setShown] = useState(() => ({ key, row: latest }));
  const [seen, setSeen] = useState(() => ({ key, at: clock() }));
  let since = seen.at;
  if (seen.key !== key) {
    since = clock();
    setSeen({ key, at: since });
  }
  const waits = key !== shown.key && isCall(key) && entryMs > 0 && clock() - since < entryMs;
  if (!waits && (key !== shown.key || latest !== shown.row)) setShown({ key, row: latest });
  useEffect(() => {
    if (!waits) return;
    const timer = setTimeout(() => setShown({ key, row: latest }), Math.max(0, since + entryMs - clock()));
    return () => clearTimeout(timer);
  }, [waits, key, latest, since, entryMs, clock]);
  return waits ? withLiveStatus(latest, shown.row) : latest;
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
