import { useEffect, useState } from "react";

/// The page's own clock for a running move, one tick per 100 ms; stopped once it ends.
export function useNow(running: boolean, fixed: number | undefined): number {
  const [now, setNow] = useState(() => fixed ?? Date.now());
  useEffect(() => {
    if (!running || fixed !== undefined) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 100);
    return () => clearInterval(timer);
  }, [running, fixed]);
  return fixed ?? now;
}
