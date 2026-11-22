// A state that is still recovering shows nothing; only one that lasts is said. On a launch or a
// daemon restart a page's link is down or connecting for a few seconds and then comes up, so a
// page that drew "disconnected", "Connecting…" or a failed attempt for it showed noise on every
// normal launch (Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD"). The page keeps its own
// retries and state; this only says when the person is told.
import { useEffect, useMemo, useRef, useState } from "react";

/// How long a link may stay down or connecting before a page says so: the agent pane's host
/// deadline (#27541, hostRetry.ts `HOST_ERROR_DEADLINE_MS`: a daemon answered 10 s after an
/// update's handoff). Past it the page shows its state as before.
export const LASTING_MS = 25_000;

let defaultGrace = LASTING_MS;

/// The grace of every `useLasting` that names none. Only the gallery's stage frames change it (to
/// 0), so a fixture that is disconnected shows that state at once instead of a blank stage.
export function setLastingGrace(ms: number): void {
  defaultGrace = ms;
}

/// Whether `active` has held for `graceMs` without a break: false until then and again as soon as
/// it ends, so a link that drops and comes back within the grace never shows. One timer while
/// `active`, cleared when it ends or the component unmounts; a grace of 0 or less is `active`.
export function useLasting(active: boolean, graceMs: number = defaultGrace): boolean {
  const [lasting, setLasting] = useState(false);
  useEffect(() => {
    if (!active || graceMs <= 0) {
      setLasting(false);
      return;
    }
    const timer = setTimeout(() => setLasting(true), graceMs);
    return () => clearTimeout(timer);
  }, [active, graceMs]);
  return active && (lasting || graceMs <= 0);
}

/// How long a page's plain "Loading…" waits before it shows: most reads answer well within it,
/// and a line that flashes on for a moment is noise (Leo, 2026-11-05: "We don't need to have so
/// much ceremony").
export const LOADING_SHOWN_MS = 1_000;

/// `useLasting` for a page's loading line: true once `active` has held for `LOADING_SHOWN_MS`. The
/// gallery's zero grace (`setLastingGrace(0)`) shows it at once, as it does every lasting state.
export function useLoadingShown(active: boolean): boolean {
  return useLasting(active, defaultGrace <= 0 ? 0 : LOADING_SHOWN_MS);
}

/// How long a connection state the person can do nothing about (reconnecting, retrying, restoring, offline,
/// disconnected) stays out of sight: the copy of schemas/notice-timing/notice-timing.json `connectionQuietMs`, checked
/// against it by scripts/cmux-next/check-connection-notices.py, which also fails a new connection state drawn with no
/// action and no bound. A state the person can act on (one button that fixes it) may show at once.
export const CONNECTION_QUIET_MS = 10_000;

/// `useLasting` for a connection state: true once `down` has held for `CONNECTION_QUIET_MS`. The gallery's zero
/// grace (`setLastingGrace(0)`) shows it at once, as it does every lasting state.
export function useConnectionQuiet(down: boolean): boolean {
  return useLasting(down, defaultGrace <= 0 ? 0 : CONNECTION_QUIET_MS);
}

const NO_KEYS: ReadonlySet<string> = new Set();

/// `useLasting` for many things at once (each machine of a list, each connector of a chat): the keys of `keys` that
/// have each been present, without a break, for `graceMs`. A key that leaves and comes back starts again. One timer,
/// for the next key to come due; none once every key is due or none is present. A grace of 0 or less is every key.
export function useLastingKeys(keys: readonly string[], graceMs: number = defaultGrace): ReadonlySet<string> {
  const joined = keys.join("\u0000");
  const since = useRef(new Map<string, number>());
  const [lasting, setLasting] = useState<ReadonlySet<string>>(NO_KEYS);
  useEffect(() => {
    const present = new Set(joined ? joined.split("\u0000") : []);
    const map = since.current;
    const start = Date.now();
    for (const key of [...map.keys()]) if (!present.has(key)) map.delete(key);
    for (const key of present) if (!map.has(key)) map.set(key, start);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const settle = () => {
      const now = Date.now();
      const due = new Set<string>();
      let next = Infinity;
      for (const [key, at] of map) {
        if (graceMs <= 0 || at + graceMs <= now) due.add(key);
        else next = Math.min(next, at + graceMs);
      }
      setLasting((was) => (was.size === due.size && [...due].every((key) => was.has(key)) ? was : due));
      if (next !== Infinity) timer = setTimeout(settle, next - now);
    };
    settle();
    return () => clearTimeout(timer);
  }, [joined, graceMs]);
  // A key that left is no longer lasting in the render that drops it, before the effect runs.
  return useMemo(() => {
    const present = joined ? joined.split("\u0000") : [];
    return new Set(graceMs <= 0 ? present : present.filter((key) => lasting.has(key)));
  }, [joined, lasting, graceMs]);
}

/// `useLastingKeys` with the connection bound (`CONNECTION_QUIET_MS`): which of many links have each been down or
/// coming up long enough to say. The gallery's zero grace shows every one at once.
export function useConnectionQuietKeys(keys: readonly string[]): ReadonlySet<string> {
  return useLastingKeys(keys, defaultGrace <= 0 ? 0 : CONNECTION_QUIET_MS);
}
