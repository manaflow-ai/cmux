// A state that is still recovering shows nothing; only one that lasts is said. On a launch or a
// daemon restart a page's link is down or connecting for a few seconds and then comes up, so a
// page that drew "disconnected", "Connecting…" or a failed attempt for it showed noise on every
// normal launch (Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD"). The page keeps its own
// retries and state; this only says when the person is told.
import { useEffect, useState } from "react";

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
