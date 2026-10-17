import { useSyncExternalStore } from "react";

/// Codex-style tool runs in a running turn (cx-ncc.108; conversation/turns.ts `codexRuns`): a
/// The Codex-style grouping is the normal transcript presentation. The host may still explicitly
/// disable it with the existing Debug tunable (`agentPane.debug.codexToolRuns`), which the app
/// pushes with the theme (`theme.codexToolRuns`, AgentPaneTheme.swift) and again when it changes.
let current = true;
const listeners = new Set<() => void>();

/// The host pushed the theme: the transcript follows at once.
export function configureCodexToolRuns(value: unknown): void {
  // Missing theme data keeps the feature on for older hosts; only an explicit false opts out.
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
