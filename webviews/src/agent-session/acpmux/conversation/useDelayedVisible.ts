import { useEffect, useState } from "react";

/// How long a wait runs before its spinner shows (Leo, 2026-11-25, "just go": a spinner only on a
/// real wait). Shorter waits finish before anything draws, so nothing flickers.
export const SPINNER_DELAY_MS = 300;

/// True once `delayMs` has passed since mount; at once when `delayMs` is 0.
export function useDelayedVisible(delayMs: number = SPINNER_DELAY_MS): boolean {
  const [visible, setVisible] = useState(delayMs <= 0);
  useEffect(() => {
    if (delayMs <= 0) {
      setVisible(true);
      return;
    }
    setVisible(false);
    const timer = setTimeout(() => setVisible(true), delayMs);
    return () => clearTimeout(timer);
  }, [delayMs]);
  return visible;
}
