// How a New Tab page parks the chat view it keeps built under it (App.tsx `premountsChatView`), so a chat
// the page takes (`acpmux-session-adopt`) only shows it.
//
// It is built under `<Activity mode="hidden">` (rendered while React is idle, no effects), then, once
// the page is idle, parked drawn but invisible and inert: the Activity turns visible, so the view's
// layout effects come back there, between frames, instead of in the adopt event's own task. Before,
// the adopt's reveal ran every one of them (`recursivelyTraverseReappearLayoutEffects`, 26 ms of the
// task at 10 turns, first-load-after-restart MODE=reopen-spare PROFILE=1).
//
// `window.__cmuxSparePark`, set before load (the bench's PARK): "hidden" keeps the view under the
// hidden Activity until the adopt (the old way), "visible" parks it drawn at once.

export type SparePark = "idle" | "hidden" | "visible";

export function sparePark(): SparePark {
  if (typeof window === "undefined") return "idle";
  const set = (window as { __cmuxSparePark?: unknown }).__cmuxSparePark;
  return set === "hidden" || set === "visible" ? set : "idle";
}

/// Idle time the park waits for: the reveal's effects (tens of ms) fit in it with no frame due.
const PARK_IDLE_MS = 40;
/// A page with no requestIdleCallback (WebKit) parks this long after it asked.
const PARK_FALLBACK_MS = 400;

/// Calls `park` once the page is idle with PARK_IDLE_MS to spare; returns the cancel.
export function whenIdleToPark(park: () => void): () => void {
  const idle = (globalThis as { requestIdleCallback?: typeof requestIdleCallback }).requestIdleCallback?.bind(
    globalThis,
  );
  if (typeof idle !== "function") {
    const timer = setTimeout(park, PARK_FALLBACK_MS);
    return () => clearTimeout(timer);
  }
  let handle = 0;
  const wait = (deadline?: IdleDeadline) => {
    if (deadline && deadline.timeRemaining() >= PARK_IDLE_MS) {
      handle = 0;
      park();
      return;
    }
    handle = idle(wait);
  };
  wait();
  return () => {
    if (handle) cancelIdleCallback(handle);
  };
}
