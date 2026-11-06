// Wires two-finger Back / Forward into a page that boots through the page bridge
// (pages/shared/pageClient.ts `createPageClient`, so every first-party page and the agent chat get
// it with no page code). The host forwards phase-aware trackpad events on the built-in stream
// `cmux.page.swipe` only for a page shown in a pane with a history (PageSwipeForwarder.swift); the
// page decides (gesture.ts, probe.ts), draws (visuals.ts) and, on a commit, asks the host to run its
// existing Go Back / Go Forward (`cmux.app.history.navigate {back}`). Once a gesture is declined or
// over, `cmux.app.swipe.release {g}` tells the host to stop forwarding it, so a vertical scroll costs
// the page a few messages, not one per frame.
//
// The page also notes its scroll and selection per history entry (restore.ts) when it leaves one,
// and puts them back in one frame when Back or Forward shows that entry again.
import { SwipeGesture, type SwipeEvent, type SwipeStep } from "./gesture";
import { keepsSwipe } from "./probe";
import { SnapshotStore, restorePage, snapshotPage } from "./restore";
import { SwipeVisuals } from "./visuals";

export const PAGE_SWIPE_STREAM = "cmux.page.swipe";
export const HISTORY_NAVIGATE_OP = "cmux.app.history.navigate";
export const SWIPE_RELEASE_OP = "cmux.app.swipe.release";
/** How many scrollers that moved the page remembers for a snapshot. */
const TRACKED_SCROLLERS = 64;

interface SwipeClient {
  call<R>(op: string, params: unknown): Promise<R>;
  subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void>;
}

const isElement = (target: EventTarget | null): target is Element => (target as Node | null)?.nodeType === 1;

const entryKey = (url: { pathname: string; search: string; hash: string }) => url.pathname + url.search + url.hash;

/** Notes scroll and selection per entry and restores them when an entry shows again. */
function installRestore(doc: Document, view: Window) {
  const store = new SnapshotStore();
  const scrolled = new Set<Element>();
  let current = entryKey(view.location);
  doc.addEventListener(
    "scroll",
    (event) => {
      const target = event.target;
      if (!isElement(target)) return;
      scrolled.delete(target);
      scrolled.add(target);
      if (scrolled.size > TRACKED_SCROLLERS) scrolled.delete(scrolled.values().next().value as Element);
    },
    { capture: true, passive: true },
  );
  const save = () => {
    for (const el of scrolled) if (!el.isConnected) scrolled.delete(el);
    store.set(current, snapshotPage(doc, scrolled));
  };
  // Capture on the window, ahead of the page's router: the DOM still shows the entry being left.
  const moved = () => {
    const next = entryKey(view.location);
    if (next === current) return;
    save();
    current = next;
    const snapshot = store.get(next);
    // After the router rendered the entry, before it paints.
    if (snapshot) view.requestAnimationFrame(() => restorePage(doc, snapshot));
  };
  view.addEventListener("popstate", moved, { capture: true });
  view.addEventListener("hashchange", moved, { capture: true });
  return { save };
}

export function installSwipeNavigation(client: SwipeClient, doc: Document = document): void {
  const view = doc.defaultView;
  if (!view) return;
  const gesture = new SwipeGesture();
  const visuals = new SwipeVisuals(doc);
  const restore = installRestore(doc, view);
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
  // Bubble on the window: the page's own handlers have run, so `defaultPrevented` is theirs.
  view.addEventListener(
    "wheel",
    (event) => {
      if (event.defaultPrevented && Math.abs(event.deltaX) > Math.abs(event.deltaY))
        preventedAt = view.performance.now();
    },
    { passive: true },
  );
  doc.addEventListener("visibilitychange", () => {
    if (doc.visibilityState === "hidden") visuals.reset();
  });

  const apply = (step: SwipeStep) => {
    switch (step.kind) {
      case "track":
        visuals.track(step);
        return;
      case "cancel":
        visuals.springBack();
        return;
      case "commit":
        restore.save();
        visuals.hold();
        // The host ran Go Back / Go Forward before it answers: the view already changed.
        void client
          .call(HISTORY_NAVIGATE_OP, { back: step.direction === "back" })
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
