import { viewStore } from "./paneViewStore";

/// Start Agent's floating chat (CmuxNextAgentPane AgentPaneFloatingState, cx-b9qi): whether the panel
/// holds a running chat, floats over other windows, and is folded to its compact bar. The App pushes
/// `floatingState` whenever it changes.
export interface FloatingState {
  readonly holding: boolean;
  readonly onTop: boolean;
  readonly collapsed: boolean;
}

// One value a pane view (paneViewStore.ts); the page itself is the null view.
const store = viewStore<FloatingState>({ holding: false, onTop: true, collapsed: false });

/// The App's push; fields it leaves out keep their value.
export function setFloatingState(value: unknown, view: string | null = null): void {
  const current = store.get(view);
  const raw = (value ?? {}) as { holding?: unknown; onTop?: unknown; collapsed?: unknown };
  const next: FloatingState = {
    holding: typeof raw.holding === "boolean" ? raw.holding : current.holding,
    onTop: typeof raw.onTop === "boolean" ? raw.onTop : current.onTop,
    collapsed: typeof raw.collapsed === "boolean" ? raw.collapsed : current.collapsed,
  };
  if (next.holding === current.holding && next.onTop === current.onTop && next.collapsed === current.collapsed) return;
  store.set(next, view);
}

export const floatingState = (view: string | null = null): FloatingState => store.get(view);

/// The live floating chat state.
export const useFloatingState = (): FloatingState => store.use();
