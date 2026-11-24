import { useEffect, useRef, useState } from "react";

/// `value`, changing at most once per `dwellMs`: a change inside the dwell waits for its end, and
/// only the newest waiting value then shows, so a burst collapses to one change.
export function useDwell<T>(value: T, dwellMs: number): T {
  const [shown, setShown] = useState(value);
  // The first value is held too: a part that mounts mid-burst (a new kind in the hat's header) shows
  // what it mounted with for a whole dwell before its first change.
  const [mountedAt] = useState(Date.now);
  const shownAt = useRef<number | undefined>(undefined);
  useEffect(() => {
    if (Object.is(value, shown)) return;
    const wait = (shownAt.current ?? mountedAt) + dwellMs - Date.now();
    const show = () => {
      shownAt.current = Date.now();
      setShown(value);
    };
    if (wait <= 0) {
      show();
      return;
    }
    const timer = setTimeout(show, wait);
    return () => clearTimeout(timer);
  }, [value, shown, dwellMs, mountedAt]);
  return shown;
}
