/// Manual transcript input suppresses automatic scrolling for this long after the last event.
export const USER_SCROLL_INTENT_MS = 1000;

const SCROLL_KEYS = new Set(["ArrowDown", "ArrowUp", "PageDown", "PageUp", "Home", "End", " ", "Spacebar"]);
type Listener = (held: boolean) => void;
type State = {
  until: number;
  timer?: ReturnType<typeof setTimeout>;
  refs: number;
  listeners: Set<Listener>;
  onWheel: (event: WheelEvent) => void;
  onPointer: () => void;
  onTouch: () => void;
  onKey: (event: KeyboardEvent) => void;
};

const states = new WeakMap<HTMLElement, State>();

function stateFor(node: HTMLElement): State {
  const existing = states.get(node);
  if (existing) return existing;
  const state: State = {
    until: 0,
    refs: 0,
    listeners: new Set(),
    onWheel: () => markUserScrollIntent(node),
    onPointer: () => markUserScrollIntent(node),
    onTouch: () => markUserScrollIntent(node),
    onKey: (event) => {
      if (SCROLL_KEYS.has(event.key)) markUserScrollIntent(node);
    },
  };
  states.set(node, state);
  return state;
}

function notify(state: State, held: boolean): void {
  for (const listener of state.listeners) listener(held);
}

/// Returns the shared intent state for one transcript scroller.
export function userScrollIntent(node: HTMLElement): {
  isHeld: () => boolean;
  mark: () => void;
  subscribe: (listener: Listener) => () => void;
} {
  const state = stateFor(node);
  return {
    isHeld: () => performance.now() < state.until,
    mark: () => markUserScrollIntent(node),
    subscribe(listener) {
      state.listeners.add(listener);
      return () => state.listeners.delete(listener);
    },
  };
}

/// Installs the one listener set owned by a transcript and clears its timer/listeners on unmount.
export function attachUserScrollIntent(node: HTMLElement): () => void {
  const state = stateFor(node);
  state.refs += 1;
  if (state.refs === 1) {
    node.addEventListener("wheel", state.onWheel, { capture: true, passive: true });
    node.addEventListener("pointerdown", state.onPointer, { capture: true, passive: true });
    node.addEventListener("touchstart", state.onTouch, { capture: true, passive: true });
    node.ownerDocument.defaultView?.addEventListener("keydown", state.onKey, { capture: true, passive: true });
  }
  return () => {
    if (state.refs === 0) return;
    state.refs -= 1;
    if (state.refs > 0) return;
    node.removeEventListener("wheel", state.onWheel, { capture: true });
    node.removeEventListener("pointerdown", state.onPointer, { capture: true });
    node.removeEventListener("touchstart", state.onTouch, { capture: true });
    node.ownerDocument.defaultView?.removeEventListener("keydown", state.onKey, { capture: true });
    clearTimeout(state.timer);
    state.timer = undefined;
    state.until = 0;
    state.listeners.clear();
  };
}

/// Records a reader event and cancels every subscribed programmatic motion immediately.
export function markUserScrollIntent(node: HTMLElement): void {
  const state = stateFor(node);
  state.until = performance.now() + USER_SCROLL_INTENT_MS;
  clearTimeout(state.timer);
  state.timer = setTimeout(() => {
    state.until = 0;
    state.timer = undefined;
    notify(state, false);
  }, USER_SCROLL_INTENT_MS);
  notify(state, true);
}
