// A Cloud machine's pause stays out of sight: the time a resume takes reads as part of thinking, so
// a note about it shows only once the wait has gone on past RESUME_NOTE_DELAY_MS (Leo, 2026-11-03:
// "The model sometimes sees a delay and you sometimes see it after sending but it evens out to not
// much at all just a tiny bit of extra time that you mostly perceive as "thinking" / But it's all
// still responsive on the ui side"). Every resume note in the pane (the composer queue's "Waking the
// machine…", the peer copy's banner, the paused card and its spinner) waits on this one threshold.
import { useEffect, useRef, useState } from "react";

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

/// How long a remote machine's link may be down, dialing or slow before the pane says so (Leo,
/// 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
/// faster/percievably load faster"): the composer row's "Reconnecting…" or "Offline", the peer copy's
/// "{machine} is offline" and a missing chat's "Reconnecting…" stay out of sight until then, and a
/// person who can act (a refused sign-in, an update) is told at once. 10 s covers acpmux's own
/// recovery: a dead ssh link is noticed in 6 s (2 s ping, 3 missed) and its redial is one ssh login
/// and two round trips (remote-reconnect-fast probe: 10 s drops back in under 0.5 s, 60 s drops in
/// 0.6 to 2.5 s), so a link that heals on its own never shows, and one that does not is said once,
/// in place.
export const LINK_DOWN_SAID_MS = 10_000;

let linkDownSaidMs = LINK_DOWN_SAID_MS;

/// The bound of every `useLinkDownSaid` that names none. Only tests and the gallery's stage frames
/// change it (a shorter wait, or 0 to draw a state at once).
export function setLinkDownSaidMs(ms: number): void {
  linkDownSaidMs = ms;
}

/// True once a link has been down (`down`) for `ms`, counted from the start of this stretch or
/// from acpmux's `since` (when the link took its current state) if that is earlier, so a chat opened
/// on a machine down for an hour says so at once while a drop under `ms` never shows. `since` moves
/// on every state change (degraded, then reconnecting, then offline); the stretch keeps its earliest
/// start until the link is up again. One timer per stretch; nothing runs at idle. `ms` 0 shows at once.
export function useLinkDownSaid(down: boolean, since?: number, ms: number = linkDownSaidMs): boolean {
  const [said, setSaid] = useState(false);
  const start = useRef<number | undefined>(undefined);
  useEffect(() => {
    if (!down) {
      start.current = undefined;
      setSaid(false);
      return;
    }
    if (ms <= 0) return;
    const now = Date.now();
    start.current = Math.min(start.current ?? now, since !== undefined && since <= now ? since : now);
    const left = ms - (now - start.current);
    if (left <= 0) {
      setSaid(true);
      return;
    }
    const timer = setTimeout(() => setSaid(true), left);
    return () => clearTimeout(timer);
  }, [down, since, ms]);
  return down && (ms <= 0 || said);
}
