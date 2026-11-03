// The worker's explicit failure marker is authoritative for code cards, even when a pool object
// already exists. One observer is shared by mounted cards; the last unsubscribe disconnects it.
const listeners = new Set<() => void>();
let observer: MutationObserver | undefined;

export function highlightWorkerFailed(): boolean {
  return typeof document !== "undefined" && document.documentElement.dataset.cmuxHighlightWorker === "failed";
}

export function subscribeHighlightWorker(listener: () => void): () => void {
  listeners.add(listener);
  if (!observer && typeof document !== "undefined" && typeof MutationObserver !== "undefined") {
    observer = new MutationObserver(() => {
      for (const notify of listeners) notify();
    });
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-cmux-highlight-worker"],
    });
  }
  return () => {
    listeners.delete(listener);
    if (!listeners.size) {
      observer?.disconnect();
      observer = undefined;
    }
  };
}
