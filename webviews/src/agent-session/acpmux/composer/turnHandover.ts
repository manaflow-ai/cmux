// Stop stays while one turn hands over to the next (Leo, 2026-11-11, on his NIGHTLY's end of a turn,
// where Stop went and came back as two other agents' messages started the next turn: "the animation
// system is so borked and unintegrated").
//
// acpmux ends a turn, then runs what waits in its queue as the next one a moment later. Between the
// two the snapshot says nothing runs, so the send slot drew Send's empty glyph (or nothing) for that
// moment and Stop came back with the next turn: the control flickered under the pointer. A turn that
// ends with something in the queue that will run (not held, not held by Stop, not waiting on the
// owner, and the queue not paused by a failure) is handing over: Stop stays, as it does for a
// prompt held while an agent starts. Pressed then it stops the turn that starts (the composer's Stop
// path, unchanged), and the queue keeps its prompts (composer.md rule 24).
//
// Bounded: the handover ends when the next turn starts, the queue empties or is held, or after
// HANDOVER_MS if no turn comes (acpmux then has something else to say: a pause, a held prompt).
// One timer only while handing over; none at rest.
import { useEffect, useState } from "react";
import type { QueuedPrompt } from "../model";

/// The longest Stop stays with nothing running before the next turn starts.
export const HANDOVER_MS = 2_000;

/// Whether `queue` holds a prompt acpmux runs next on its own.
export function runsNext(queue: readonly QueuedPrompt[], paused: boolean): boolean {
  return !paused && queue.some((entry) => !entry.held && !entry.heldByStop && !entry.awaitingOwner);
}

/// Whether the chat is between a turn that ended and the queued turn acpmux starts next.
export function useTurnHandover(working: boolean, queue: readonly QueuedPrompt[], paused: boolean): boolean {
  const next = runsNext(queue, paused);
  // The turn that ran last render: a handover starts only from a running turn, never at rest.
  const [state, setState] = useState({ working, handing: false });
  if (state.working !== working || (state.handing && (!next || working)))
    setState({ working, handing: !working && state.working && next });
  const handing = state.handing && !working && next;
  useEffect(() => {
    if (!handing) return undefined;
    const timer = setTimeout(() => setState((current) => ({ ...current, handing: false })), HANDOVER_MS);
    return () => clearTimeout(timer);
  }, [handing]);
  return handing;
}
