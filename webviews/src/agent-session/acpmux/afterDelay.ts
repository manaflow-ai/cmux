// A Cloud machine's pause stays out of sight: the time a resume takes reads as part of thinking, so
// a note about it shows only once the wait has gone on past RESUME_NOTE_DELAY_MS (Leo, 2026-11-03:
// "The model sometimes sees a delay and you sometimes see it after sending but it evens out to not
// much at all just a tiny bit of extra time that you mostly perceive as "thinking" / But it's all
// still responsive on the ui side"). Every resume note in the pane (the composer queue's "Waking the
// machine…", the peer copy's banner, the paused card and its spinner) waits on this one threshold.
import { useEffect, useMemo, useRef, useState } from "react";

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

/// How long a transient entry (a queued prompt or message that may go again within an event batch
/// or two at a turn's boundary) stays out of sight before it paints (Leo, 2026-11-17: "i also dont
/// like seeing the flicker flash of the Queued blah blah blah something"). 200 ms is past the gap
/// between a turn's end and the queue's drain, and under what reads as a lag after a send.
export const TRANSIENT_SHOW_MS = 200;

type Settled = {
  scope: unknown;
  /// Ids that have stayed `ms`, or were there when the list (or its scope) was first drawn.
  ids: ReadonlySet<string>;
};

/// `items` less the ones that have not stayed present for `ms` yet: an entry added and removed
/// within `ms` never shows, one that stays shows `ms` after it came. Items there at the first render,
/// or when `scope` changes (another chat shown), show at once, as does any `immediate` one (an entry
/// that waits on the person, never a transient). `items` itself comes back when all show, so memos
/// downstream keep their identity. Each waiting id keeps the time it came across renders; its timer
/// is cleared when the list changes or the component goes: nothing runs at idle.
export function useSettledItems<T>(
  items: readonly T[],
  id: (item: T) => string,
  scope: unknown,
  ms: number = TRANSIENT_SHOW_MS,
  immediate?: (item: T) => boolean,
): readonly T[] {
  const [settled, setSettled] = useState<Settled>(() => ({ scope, ids: new Set(items.map(id)) }));
  // When each waiting id came, read and written in effects only.
  const cameAt = useRef(new Map<string, number>());
  const present = useMemo(() => new Set(items.map(id)), [items, id]);
  // Another chat: what it holds shows at once. An id gone from the list is forgotten, so one that
  // comes again waits again (state adjusted while rendering, as React's docs do for a changed prop).
  if (settled.scope !== scope) setSettled({ scope, ids: present });
  else if ([...settled.ids].some((key) => !present.has(key)))
    setSettled({ scope, ids: new Set([...settled.ids].filter((key) => present.has(key))) });
  useEffect(() => {
    const came = cameAt.current;
    for (const key of came.keys()) if (!present.has(key) || settled.ids.has(key)) came.delete(key);
    if (ms <= 0) return undefined;
    const now = Date.now();
    const timers: ReturnType<typeof setTimeout>[] = [];
    for (const item of items) {
      const key = id(item);
      if (settled.ids.has(key) || immediate?.(item)) continue;
      const at = came.get(key) ?? now;
      came.set(key, at);
      timers.push(
        setTimeout(
          () =>
            setSettled((was) =>
              was.scope !== scope || was.ids.has(key) ? was : { scope, ids: new Set([...was.ids, key]) },
            ),
          Math.max(0, ms - (now - at)),
        ),
      );
    }
    return () => timers.forEach(clearTimeout);
  }, [items, id, scope, ms, immediate, present, settled]);
  return useMemo(() => {
    if (ms <= 0 || settled.scope !== scope) return items;
    const shown = items.filter((item) => settled.ids.has(id(item)) || immediate?.(item) === true);
    return shown.length === items.length ? items : shown;
  }, [items, id, scope, ms, immediate, settled]);
}
