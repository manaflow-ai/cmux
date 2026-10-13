import { useSyncExternalStore } from "react";

/// Start Agent's floating chat (CmuxNextAgentPane AgentPaneFloatingState, cx-b9qi): whether the panel
/// holds a running chat, floats over other windows, and is folded to its compact bar. The App pushes
/// `floatingState` whenever it changes.
export interface FloatingState {
  readonly holding: boolean;
  readonly onTop: boolean;
  readonly collapsed: boolean;
}

let current: FloatingState = { holding: false, onTop: true, collapsed: false };
const listeners = new Set<() => void>();

/// The App's push; fields it leaves out keep their value.
export function setFloatingState(value: unknown): void {
  const raw = (value ?? {}) as { holding?: unknown; onTop?: unknown; collapsed?: unknown };
  const next: FloatingState = {
    holding: typeof raw.holding === "boolean" ? raw.holding : current.holding,
    onTop: typeof raw.onTop === "boolean" ? raw.onTop : current.onTop,
    collapsed: typeof raw.collapsed === "boolean" ? raw.collapsed : current.collapsed,
  };
  if (next.holding === current.holding && next.onTop === current.onTop && next.collapsed === current.collapsed) return;
  current = next;
  for (const listener of listeners) listener();
}

export const floatingState = (): FloatingState => current;

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// The live floating chat state.
export const useFloatingState = (): FloatingState => useSyncExternalStore(subscribe, floatingState, floatingState);
