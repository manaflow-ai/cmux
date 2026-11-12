import { railOwnsWheel } from "../threadMinimap/railWheel";

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
/// What a press on is a click rather than the start of a drag or a scroll.
const CONTROLS =
  "button, a[href], input, textarea, select, summary, label, [role=button], [role=menuitem], [contenteditable=true], [contenteditable='']";
/// How far a press travels before it is a drag (a selection pulling the view, the scrollbar's thumb)
/// rather than a click that shook a little.
const PRESS_SLOP_PX = 4;
/// What an input is: one that scrolls (a wheel, a touch moving, a scroll key, a drag, a press on the
/// scrollbar), a press on the rows that has not moved yet, or one that leaves that as it was (a
/// release, a press moving within its slop).
type Input = "scroll" | "press" | "same";
type Listener = (event?: Event) => void;
const states = new WeakMap<HTMLElement, ReturnType<typeof createIntent>>();

function createIntent() {
  let at = -Infinity;
  let generation = 0;
  let pressed = false;
  /// Whether the newest input scrolls (`Input`): a press on text holds automatic motion like any
  /// input, but moves nothing by itself.
  let scrolling = false;
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
    /// Held by an input that scrolls: the reader moved the view by hand. A press on text that has not
    /// moved, or its release, holds the view but is no scroll: a click to select while scrolled up
    /// must not read as the reader scrolling.
    scrolledByHand(): boolean {
      return scrolling && this.isHeld();
    },
    // An explicit request may start during the hold, but its continuations expire on later input.
    request: () => {
      const started = generation;
      return () => generation === started;
    },
    mark(event?: Event, input: Input = "scroll") {
      if (input !== "same") scrolling = input === "scroll";
      at = performance.now();
      generation += 1;
      scheduleQuiet();
      for (const listener of listeners) listener(event);
    },
    press(value: boolean) {
      pressed = value;
      scheduleQuiet();
    },
    /// A drag that ended without its pointerup (no buttons on the next move, or the window lost
    /// focus): the quiet interval starts now, as at a release. Not new input, so explicit
    /// requests made since the drag stay valid.
    release() {
      pressed = false;
      at = performance.now();
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
  // A wheel over a rail that scrolls itself moves the rail, not the transcript (railWheel.ts).
  const mark = (event: Event, input?: Input) => {
    if (!railOwnsWheel(event)) intent.mark(event, input);
  };
  /// Where the press began, for its slop (`PRESS_SLOP_PX`); undefined once it moved past it.
  let pressAt: { x: number; y: number } | undefined;
  const pointAt = (event: Event) => {
    const point = (event as TouchEvent).touches?.[0] ?? (event as PointerEvent);
    return typeof point.clientX === "number" ? { x: point.clientX, y: point.clientY } : undefined;
  };
  const down = (event: Event) => {
    // A press on a control (Reply, a disclosure, a link) is a click, not a scroll: what it opens
    // may still be followed into view. A press on text or the scrollbar is scroll input.
    if ((event.target as Element | null)?.closest?.(CONTROLS)) return;
    pressed = true;
    intent.press(true);
    // The scrollbar (the scroller itself) scrolls at the press; a press on the rows only once it drags.
    const onScrollbar = event.target === node;
    pressAt = onScrollbar ? undefined : pointAt(event);
    mark(event, onScrollbar || !pressAt ? "scroll" : "press");
  };
  const move = (event: Event) => {
    if (!pressed) return;
    // A scrollbar drag can leave the window without a pointerup. The next pointermove reports
    // buttons=0; clear the drag before ordinary hovering can keep invalidating motion.
    if ((event as PointerEvent).buttons === 0) {
      pressed = false;
      intent.release();
      return;
    }
    const point = pointAt(event);
    if (pressAt && point && Math.hypot(point.x - pressAt.x, point.y - pressAt.y) > PRESS_SLOP_PX) pressAt = undefined;
    mark(event, pressAt ? "same" : "scroll");
  };
  const up = (event: Event) => {
    if (!pressed) return;
    pressed = false;
    intent.press(false);
    mark(event, "same");
  };
  const blur = () => {
    if (!pressed) return;
    pressed = false;
    intent.release();
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
