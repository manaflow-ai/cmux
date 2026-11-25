import { flushSync } from "react-dom";

/// Runs `read` once, at the first frame's layout of `node` (a ResizeObserver's first delivery), not
/// now. A layout effect that reads a computed style or a box right after the commit makes the page
/// resolve its style and layout then, a pass of its own (8 ms each over a restored chat, in the
/// first-load-after-restart bench's profile), and again when the frame draws. Read here, at the
/// frame's own layout, those values are already resolved, and a state the read sets still renders
/// before that frame paints (`flushSync`), so nothing draws at the unmeasured size. Without
/// ResizeObserver it reads now. Returns the stop for an effect's cleanup.
export function readAtFirstLayout(node: Element, read: () => void): () => void {
  const View = node.ownerDocument.defaultView?.ResizeObserver ?? globalThis.ResizeObserver;
  if (typeof View !== "function") {
    read();
    return () => {};
  }
  const observer = new View(() => {
    observer.disconnect();
    flushSync(read);
  });
  observer.observe(node);
  return () => observer.disconnect();
}
