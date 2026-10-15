import { useSyncExternalStore } from "react";

/// Codex-style tool runs in a running turn (cx-ncc.108; conversation/turns.ts `codexRuns`): a
/// Debug toggle (`agentPane.debug.codexToolRuns`, CmuxNextAgentPane AgentPaneTunables), off by
/// default, which the app pushes with the theme (`theme.codexToolRuns`, AgentPaneTheme.swift) and
/// again when it changes, as it does the chat width (chatWidth.ts).
let current = false;
const listeners = new Set<() => void>();

/// The host pushed the theme: the transcript follows at once.
export function configureCodexToolRuns(value: unknown): void {
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
