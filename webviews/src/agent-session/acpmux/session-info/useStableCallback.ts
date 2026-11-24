import { useMemo, useRef } from "react";

/// Keep event props stable while retaining the latest callback. The pane owns transcript scroll
/// state, so a fresh inline callback would defeat the SessionInfoPresence memo.
export function useStableCallback<T extends (...args: never[]) => unknown>(callback: T | undefined): T | undefined {
  const current = useRef<T | undefined>(callback);
  current.current = callback;
  const enabled = callback !== undefined;
  return useMemo(
    () => (enabled ? (((...args: Parameters<T>) => current.current?.(...args)) as T) : undefined),
    [enabled],
  );
}
