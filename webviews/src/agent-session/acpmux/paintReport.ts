// When the page tells the host it drew what it is (`pane.painted`, App.tsx): one animation frame
// after that render, then a task, so the task runs once that frame was drawn (cx-zjtn.6).

function defaultDocument(): Document | undefined {
  return typeof document === "undefined" ? undefined : document;
}

/// Runs `report` after the frame that drew the current render.
export function afterDrawnFrame(report: () => void, doc: Document | undefined = defaultDocument()): void {
  const view = doc?.defaultView as (Window & typeof globalThis) | null | undefined;
  const raf = view?.requestAnimationFrame?.bind(view) ?? requestAnimationFrame;
  raf(() => setTimeout(report, 0));
}
