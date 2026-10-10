import { useSyncExternalStore } from "react";

/// What the chat header shows from the chat's tab (CmuxNextAgentPane AgentPaneHeaderState): the pin the
/// "..." menu's labels read, whether the panes beside the chat show ([+] New tab reads Hide tabs), and
/// the header splits whose toggle is lit because the split it opened is open (cx-00n1). The page reads it
/// with `pane.tabState` when a chat opens; the App pushes `headerState` whenever it changes, so a split
/// the user closes from its own tab turns its button off at once.
export interface HeaderState {
  readonly pinned: boolean;
  readonly sideTabs: boolean;
  /// App action ids (`splitRight`, `splitBrowserRight`).
  readonly lit: readonly string[];
}

let current: HeaderState = { pinned: false, sideTabs: false, lit: [] };
const listeners = new Set<() => void>();

/// The App's state (a `pane.tabState` reply or a `headerState` push); fields it leaves out keep their value.
export function setHeaderState(value: unknown): void {
  const raw = (value ?? {}) as { pinned?: unknown; sideTabs?: unknown; lit?: unknown };
  const next: HeaderState = {
    pinned: typeof raw.pinned === "boolean" ? raw.pinned : current.pinned,
    sideTabs: typeof raw.sideTabs === "boolean" ? raw.sideTabs : current.sideTabs,
    lit: Array.isArray(raw.lit) ? raw.lit.filter((id): id is string => typeof id === "string") : current.lit,
  };
  if (JSON.stringify(next) === JSON.stringify(current)) return;
  current = next;
  for (const listener of listeners) listener();
}

export const headerState = (): HeaderState => current;

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// The live header state.
export const useHeaderState = (): HeaderState => useSyncExternalStore(subscribe, headerState, headerState);
