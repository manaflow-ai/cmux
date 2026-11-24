// Starts work that a render found due: a value read again because the view reloaded or because
// an option that needs it was turned on. Kept out of components so they hold no effects.
import { useEffect, useRef } from "react";

/// Calls `start` after each commit in which `due` turns true (and after the first commit when it
/// starts true). `start` must make `due` false (for example by moving its state to loading), so
/// it runs once per need; the latest `start` is the one called.
export function useStartWhenDue(due: boolean, start: () => void) {
  const latest = useRef(start);
  latest.current = start;
  useEffect(() => {
    if (due) latest.current();
  }, [due]);
}
