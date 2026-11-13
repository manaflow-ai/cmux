// Wires two-finger Back / Forward into a page that boots through the page bridge
// (pages/shared/pageClient.ts `createPageClient`, so every first-party page and the agent chat get
// it with no page code). The host forwards phase-aware trackpad events on the built-in stream
// `cmux.page.swipe` only for a page shown in a pane with a history (PageSwipeForwarder.swift); the
// page decides (gesture.ts, probe.ts), draws (visuals.ts) and, on a commit, asks the host to run its
// existing Go Back / Go Forward (`cmux.app.history.navigate {back, g}`). Once a gesture is declined or
// over, `cmux.app.swipe.release {g}` tells the host to stop forwarding it, so a vertical scroll costs
// the page a few messages, not one per frame.
import { SwipeGesture, type SwipeEvent, type SwipeStep } from "./gesture";
import { keepsSwipe } from "./probe";
import { SwipeVisuals } from "./visuals";

export const PAGE_SWIPE_STREAM = "cmux.page.swipe";
export const HISTORY_NAVIGATE_OP = "cmux.app.history.navigate";
export const SWIPE_RELEASE_OP = "cmux.app.swipe.release";
interface SwipeClient {
  call<R>(op: string, params: unknown): Promise<R>;
  subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void>;
}

const isElement = (target: EventTarget | null): target is Element => (target as Node | null)?.nodeType === 1;

/**
 * Calls `onPrevented` with the time of each horizontal wheel the page's own code took
 * (`preventDefault`): a carousel keeps swipes off. A capture listener on the window runs before any
 * page handler can stop the event, and reads `defaultPrevented` once dispatch has finished.
 */
export function watchPreventedWheels(view: Window, onPrevented: (at: number) => void): void {
  view.addEventListener(
    "wheel",
    (event) => {
      if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return;
      view.setTimeout(() => {
        if (event.defaultPrevented) onPrevented(view.performance.now());
      }, 0);
    },
    { capture: true, passive: true },
  );
}

export function installSwipeNavigation(client: SwipeClient, doc: Document = document): void {
  const view = doc.defaultView;
  if (!view) return;
  const gesture = new SwipeGesture();
  const visuals = new SwipeVisuals(doc);
  let target: Element | null = null;
  let preventedAt = -Infinity;
  let released: number | undefined;
  view.addEventListener(
    "wheel",
    (event) => {
      target = isElement(event.target) ? event.target : null;
    },
    { capture: true, passive: true },
  );
  watchPreventedWheels(view, (at) => (preventedAt = at));
  doc.addEventListener("visibilitychange", () => {
    if (doc.visibilityState === "hidden") visuals.reset();
  });

  const apply = (step: SwipeStep, g: number | undefined) => {
    switch (step.kind) {
      case "track":
        visuals.track(step);
        return;
      case "cancel":
        visuals.springBack();
        return;
      case "commit":
        visuals.hold();
        // The host ran Go Back / Go Forward before it answers: the view already changed.
        void client
          // The host runs it only for the live gesture it forwarded (its id), once.
          .call(HISTORY_NAVIGATE_OP, { back: step.direction === "back", g })
          .catch(() => undefined)
          .finally(() => visuals.reset());
        return;
      case "none":
        return;
    }
  };

  const onEvent = (event: SwipeEvent) => {
    const carry = event.phase === "began" && !event.momentum ? visuals.interrupt() : 0;
    apply(
      gesture.feed(event, {
        width: view.innerWidth,
        carry,
        keeps: (direction) => keepsSwipe(target, direction, { now: view.performance.now(), preventedAt }),
      }),
      event.g,
    );
    const over = gesture.mode === "declined" || event.phase === "ended" || event.phase === "cancelled";
    if (event.g !== undefined && event.g !== released && !event.momentum && over) {
      released = event.g;
      void client.call(SWIPE_RELEASE_OP, { g: event.g }).catch(() => undefined);
    }
  };
  // A host without the stream (an older app, a mock provider) leaves the page as it was.
  void client.subscribe<SwipeEvent>(PAGE_SWIPE_STREAM, onEvent).catch(() => undefined);
}
