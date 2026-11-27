import { useEffect, useRef, useState } from "react";

export type NativeOperations = Readonly<Record<string, "pending" | "failed">>;

/// Stop feedback lives in the page as it does in StopButton: successful stops stay pending until
/// the snapshot removes the running row, failed stops may be retried. A click cannot submit twice.
export function useNativeOperations(active: readonly string[]) {
  const [operations, setOperations] = useState<NativeOperations>({});
  const current = useRef<NativeOperations>({});
  const live = useRef(false);
  useEffect(() => {
    const keys = new Set(active);
    const entries = Object.entries(current.current);
    if (entries.every(([key]) => keys.has(key))) return;
    current.current = Object.fromEntries(entries.filter(([key]) => keys.has(key)));
    setOperations(current.current);
  }, [active]);
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  const run = (key: string, request: () => Promise<unknown>) => {
    if (current.current[key] === "pending") return;
    current.current = { ...current.current, [key]: "pending" };
    setOperations(current.current);
    return Promise.resolve()
      .then(request)
      .catch(() => {
        if (!live.current || !current.current[key]) return;
        current.current = { ...current.current, [key]: "failed" };
        setOperations(current.current);
      });
  };
  return { operations, run };
}
