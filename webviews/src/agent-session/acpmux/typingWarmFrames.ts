/**
 * Keeps the page's frame clock running while the person types in a composer, so the next key's edit
 * paints on the next display frame instead of first waking the renderer and joining the frame clock.
 *
 * Measured (scripts/cmux-next/typing-frame-bench.py, agent chat, 200 keys, 120 Hz, base 17ef79a5): with
 * the focused chat idle a key reached paint at p50 8.3 ms / p95 14.5 ms; with the same chat already
 * drawing frames (a stream: modes L1, L3) at p50 2.1-2.9 ms / p95 8.3-8.6 ms. The page's own per-key
 * script is about 2.6 ms either way: the idle cost is the wake (key to listener p50 3.1 ms idle, 0.4-1.1
 * ms drawing) and the wait for the first frame after it (key to frame p50 6.8 ms idle, 1.7-2.5 ms drawing).
 *
 * An empty requestAnimationFrame callback per frame keeps both warm. It runs only from a composer key or
 * focus until `holdMs` after the last one, and never while the page is hidden: an idle composer costs
 * nothing, and a burst of typing costs one empty callback per frame (no layout, no paint: nothing changed).
 */

/** The composers it serves: the chat's and the New Tab page's (the same set the typing marks use, perf.ts). */
export const TYPING_WARM_SELECTOR = ".acpmux-composer, .nt-composer";

/** How long frames stay warm after the last key or focus: longer than a pause between words. */
export const TYPING_WARM_HOLD_MS = 1500;

export interface TypingWarmFramesHost {
  addEventListener(type: string, listener: (event: Event) => void, options?: boolean | AddEventListenerOptions): void;
  removeEventListener(type: string, listener: (event: Event) => void, options?: boolean | EventListenerOptions): void;
  readonly visibilityState?: DocumentVisibilityState;
}

export interface TypingWarmFramesOptions {
  holdMs?: number;
  now?: () => number;
  requestFrame?: (callback: () => void) => unknown;
}

export interface TypingWarmFrames {
  /** Whether a warm loop is running now (tests). */
  readonly running: boolean;
  /** How many frames the loop has asked for (tests). */
  readonly frames: number;
  dispose(): void;
}

export function installTypingWarmFrames(
  host: TypingWarmFramesHost,
  options: TypingWarmFramesOptions = {},
): TypingWarmFrames {
  const holdMs = options.holdMs ?? TYPING_WARM_HOLD_MS;
  const now = options.now ?? (() => performance.now());
  const requestFrame = options.requestFrame ?? ((callback: () => void) => requestAnimationFrame(callback));
  let until = 0;
  let running = false;
  let disposed = false;
  let frames = 0;

  const tick = () => {
    if (disposed || host.visibilityState === "hidden" || now() >= until) {
      running = false;
      return;
    }
    frames++;
    requestFrame(tick);
  };
  const warm = (event: Event) => {
    const element = event.target as Element | null;
    if (!element?.closest?.(TYPING_WARM_SELECTOR)) return;
    until = now() + holdMs;
    if (running || disposed) return;
    running = true;
    frames++;
    requestFrame(tick);
  };
  host.addEventListener("keydown", warm, true);
  host.addEventListener("focusin", warm, true);
  return {
    get running() {
      return running;
    },
    get frames() {
      return frames;
    },
    dispose() {
      disposed = true;
      host.removeEventListener("keydown", warm, true);
      host.removeEventListener("focusin", warm, true);
    },
  };
}
