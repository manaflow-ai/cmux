// A state that is still recovering shows nothing; only one that lasts is said. On a launch or a
// daemon restart a page's link is down or connecting for a few seconds and then comes up, so a
// page that drew "disconnected", "Connecting…" or a failed attempt for it showed noise on every
// normal launch (Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD"). The page keeps its own
// retries and state; this only says when the person is told.
import { useEffect, useRef, useState } from "react";

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

/// When each keyed row's connection state was first drawn as down, shared by every surface that draws the row, so
/// a row the tray, the summary and the end line all draw waits once and they never disagree.
const downSince = new Map<string, number>();

/// Whether a keyed row's connection state has lasted: `lasting(key, down)`, `useConnectionQuiet` for a list whose
/// rows go down and come back each on their own (a subagent's retry, a connector's connect). One timer per
/// component, set to the soonest row still waiting; a row that comes back forgets when it went down. `now` is the
/// clock (tests inject one). The gallery's zero grace (`setLastingGrace(0)`) shows every row at once.
export function useConnectionQuietKeys(now: () => number = Date.now): (key: string, down: boolean) => boolean {
  const [, redraw] = useState(0);
  const soonest = useRef(Number.POSITIVE_INFINITY);
  soonest.current = Number.POSITIVE_INFINITY;
  useEffect(() => {
    if (soonest.current === Number.POSITIVE_INFINITY) return;
    const timer = setTimeout(() => redraw((n) => n + 1), Math.max(0, soonest.current - now()));
    return () => clearTimeout(timer);
  });
  const grace = defaultGrace <= 0 ? 0 : CONNECTION_QUIET_MS;
  return (key, down) => {
    if (!down) {
      downSince.delete(key);
      return false;
    }
    if (grace <= 0) return true;
    const at = now();
    const since = downSince.get(key) ?? at;
    downSince.set(key, since);
    if (at - since >= grace) return true;
    soonest.current = Math.min(soonest.current, since + grace);
    return false;
  };
}
