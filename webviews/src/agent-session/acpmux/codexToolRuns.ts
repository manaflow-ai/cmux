import { useSyncExternalStore } from "react";

/// Codex-style tool runs (cx-ncc.108; conversation/turns.ts `codexRuns`): finished runs fold into
/// summary lines between the paragraphs and the call in flight is the live line. On by default;
/// the native host sends the Debug toggle's value with the theme, and only an explicit false turns
/// it off.
let current = true;
const listeners = new Set<() => void>();

/// The host pushed the theme: the transcript follows at once.
export function configureCodexToolRuns(value: unknown): void {
  // Native AgentPaneTunables sends true by default; missing theme data keeps the default.
  const next = value !== false;
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// Whether the toggle is on now.
export const useCodexToolRuns = (): boolean => useSyncExternalStore(subscribe, snapshot, snapshot);
