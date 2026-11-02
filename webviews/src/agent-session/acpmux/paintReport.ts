// When the page tells the host it drew what it is (`pane.painted`, App.tsx): one animation frame
// after that render, then a task, so the task runs once that frame was drawn (cx-zjtn.6).
//
// A hidden document runs no animation frames at all. The host's prewarmed spare page can be hidden
// in its parking (Chromium marks the page hidden), and a tab opening an existing chat adopts it
// there (AgentPaneView+SessionAdopt.swift). The host keeps the adopted page away and covered until
// this report comes, and the cover is what keeps it hidden. Waiting for a frame then waited for
// nothing: reopens held their cover for the loading state's ~15 s give-up (HQ#5914, the chat-open
// bench at 7d8c57e6: `visibilityState` "hidden", the last animation frame before the report was
// asked). A hidden page reports on a task, at once or when it goes hidden while it waits; the host
// shows the page then, and Chromium draws it in place.

function defaultDocument(): Document | undefined {
  return typeof document === "undefined" ? undefined : document;
}

/// Runs `report` once, after the frame that drew the current render, or on a task when the
/// document is hidden (now or before that frame comes). Its one listener goes when it runs.
export function afterDrawnFrame(report: () => void, doc: Document | undefined = defaultDocument()): void {
  let done = false;
  const onHidden = () => {
    if (doc?.visibilityState === "hidden") run();
  };
  const run = () => {
    if (done) return;
    done = true;
    doc?.removeEventListener("visibilitychange", onHidden);
    setTimeout(report, 0);
  };
  const view = doc?.defaultView as (Window & typeof globalThis) | null | undefined;
  const raf = view?.requestAnimationFrame?.bind(view);
  if (!doc || doc.visibilityState === "hidden" || typeof raf !== "function") return run();
  doc.addEventListener("visibilitychange", onHidden);
  raf(run);
}
