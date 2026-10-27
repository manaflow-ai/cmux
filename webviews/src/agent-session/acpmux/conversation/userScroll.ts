/// Automatic transcript motion yields for one second after the last manual input.
export const USER_SCROLL_INTENT_MS = 1000;
const SCROLL_KEYS = new Set([
  "ArrowDown",
  "ArrowUp",
  "ArrowLeft",
  "ArrowRight",
  "PageDown",
  "PageUp",
  "Home",
  "End",
  " ",
  "Spacebar",
]);
type Listener = (event?: Event) => void;
const states = new WeakMap<HTMLElement, ReturnType<typeof createIntent>>();

function createIntent() {
  let at = -Infinity;
  let generation = 0;
  let pressed = false;
  const listeners = new Set<Listener>();
  const quietListeners = new Set<() => void>();
  let quietTimer: ReturnType<typeof setTimeout> | undefined;
  const scheduleQuiet = () => {
    clearTimeout(quietTimer);
    quietTimer = undefined;
    if (pressed || quietListeners.size === 0 || at === -Infinity) return;
    quietTimer = setTimeout(
      () => {
        quietTimer = undefined;
        if (performance.now() - at < USER_SCROLL_INTENT_MS) {
          scheduleQuiet();
          return;
        }
        for (const listener of quietListeners) listener();
      },
      Math.max(1, Math.ceil(USER_SCROLL_INTENT_MS - (performance.now() - at))),
    );
  };
  return {
    isHeld: () => pressed || performance.now() - at < USER_SCROLL_INTENT_MS,
    // An explicit request may start during the hold, but its continuations expire on later input.
    request: () => {
      const started = generation;
      return () => generation === started;
    },
    mark(event?: Event) {
      at = performance.now();
      generation += 1;
      scheduleQuiet();
      for (const listener of listeners) listener(event);
    },
    press(value: boolean) {
      pressed = value;
      scheduleQuiet();
    },
    subscribe(listener: Listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    subscribeQuiet(listener: () => void) {
      quietListeners.add(listener);
      scheduleQuiet();
      return () => {
        quietListeners.delete(listener);
        if (quietListeners.size === 0) {
          clearTimeout(quietTimer);
          quietTimer = undefined;
        }
      };
    },
    reset() {
      this.mark();
      at = -Infinity;
      pressed = false;
      clearTimeout(quietTimer);
      quietTimer = undefined;
    },
  };
}

/// One stable signal per scroller. Reading it allocates nothing per token or frame.
export function userScrollIntent(node: HTMLElement) {
  let state = states.get(node);
  if (!state) {
    state = createIntent();
    states.set(node, state);
  }
  return state;
}

/// Capture input before row handlers can commit layout. Quiet subscribers share one expiry timer.
/// Pointer/touch holds outlast one second while dragging; release starts the quiet interval.
export function attachUserScrollIntent(node: HTMLElement): () => void {
  const intent = userScrollIntent(node);
  const page = node.ownerDocument;
  let pressed = false;
  const mark = (event: Event) => intent.mark(event);
  const down = (event: Event) => {
    pressed = true;
    intent.press(true);
    mark(event);
  };
  const move = (event: Event) => {
    if (!pressed) return;
    // A scrollbar drag can leave the window without a pointerup. The next pointermove reports
    // buttons=0; clear the drag before ordinary hovering can keep invalidating motion.
    if ((event as PointerEvent).buttons === 0) {
      pressed = false;
      intent.press(false);
      return;
    }
    mark(event);
  };
  const up = (event: Event) => {
    if (!pressed) return;
    pressed = false;
    intent.press(false);
    mark(event);
  };
  const blur = () => {
    if (!pressed) return;
    pressed = false;
    intent.press(false);
  };
  const key = (event: KeyboardEvent) => {
    const target = event.target as HTMLElement | null;
    if (!SCROLL_KEYS.has(event.key) || target?.closest?.("input, textarea, select, [contenteditable=true]")) return;
    // Scroll keys in another pane/composer do not take this transcript away from its reader.
    if (!node.contains(target) && target !== page.body) return;
    mark(event);
  };
  node.addEventListener("wheel", mark, { capture: true, passive: true });
  node.addEventListener("pointerdown", down, { capture: true, passive: true });
  node.addEventListener("touchstart", down, { capture: true, passive: true });
  node.addEventListener("touchmove", mark, { capture: true, passive: true });
  page.addEventListener("pointermove", move, { capture: true, passive: true });
  page.addEventListener("pointerup", up, true);
  page.addEventListener("pointercancel", up, true);
  page.addEventListener("touchend", up, true);
  page.addEventListener("touchcancel", up, true);
  page.defaultView?.addEventListener("blur", blur, true);
  page.addEventListener("keydown", key, true);
  return () => {
    node.removeEventListener("wheel", mark, true);
    node.removeEventListener("pointerdown", down, true);
    node.removeEventListener("touchstart", down, true);
    node.removeEventListener("touchmove", mark, true);
    page.removeEventListener("pointermove", move, true);
    page.removeEventListener("pointerup", up, true);
    page.removeEventListener("pointercancel", up, true);
    page.removeEventListener("touchend", up, true);
    page.removeEventListener("touchcancel", up, true);
    page.defaultView?.removeEventListener("blur", blur, true);
    page.removeEventListener("keydown", key, true);
    intent.reset();
  };
}
