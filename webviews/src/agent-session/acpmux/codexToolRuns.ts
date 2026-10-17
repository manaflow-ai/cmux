import { useSyncExternalStore } from "react";

/// Codex-style tool runs in a running turn (cx-ncc.108; conversation/turns.ts `codexRuns`): a
/// The native host sends the tunable's default explicitly. A browser or older host that has not
/// sent a theme keeps the legacy web fallback until it opts into Codex-style live grouping.
let current = false;
const listeners = new Set<() => void>();

/// The host pushed the theme: the transcript follows at once.
export function configureCodexToolRuns(value: unknown): void {
  // Native AgentPaneTunables sends true by default; missing theme data stays compatible with
  // browser and older hosts until they explicitly opt in.
  const next = value === true;
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
