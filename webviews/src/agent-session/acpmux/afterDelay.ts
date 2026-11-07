// A Cloud machine's pause stays out of sight: the time a resume takes reads as part of thinking, so
// a note about it shows only once the wait has gone on past RESUME_NOTE_DELAY_MS (Leo, 2026-11-03:
// "The model sometimes sees a delay and you sometimes see it after sending but it evens out to not
// much at all just a tiny bit of extra time that you mostly perceive as "thinking" / But it's all
// still responsive on the ui side"). Every resume note in the pane (the composer queue's "Waking the
// machine…", the peer copy's banner, the paused card and its spinner) waits on this one threshold.
import { useEffect, useState } from "react";

/// How long a pause or resume stays invisible before the pane says anything about it.
export const RESUME_NOTE_DELAY_MS = 1_500;

/// True once `active` has held for `ms` without a break; false at once when it ends. One timer per
/// stretch of `active`, cleared when it ends or the component goes: nothing runs at idle. `ms` 0
/// shows at once (the gallery's settled variants).
export function useAfterDelay(active: boolean, ms: number = RESUME_NOTE_DELAY_MS): boolean {
  const [elapsed, setElapsed] = useState(false);
  useEffect(() => {
    setElapsed(false);
    if (!active || ms <= 0) return;
    const timer = setTimeout(() => setElapsed(true), ms);
    return () => clearTimeout(timer);
  }, [active, ms]);
  return active && (ms <= 0 || elapsed);
}
