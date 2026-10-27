// Frame tests read what the page painted, once per frame, after that frame's rendering.
//
// A requestAnimationFrame callback runs before the frame's style, layout, ResizeObserver callbacks
// and paint. A read there sees the layout as it stands before the observers that size the page
// (the transcript's room under its last row, for one) have run, a state the frame may never paint:
// a probe read in a frame callback showed the last row 30 px low on the first frame of an opened
// chat, and nobody saw it (scroll-jitter, 2026-10-21). A message posted from the frame callback
// runs as a task after the frame has rendered, so every read here is of a painted state. Input the
// browser handles between the frame and that task would change the page the read lays out, a
// state no frame painted (a composer card a line taller than the lift its frame painted,
// scroll-jitter 2026-10-21): the first input event after a frame runs its read at once instead,
// from a capturing listener on the window that comes before the page's own handlers. (The pointer's
// :hover and :active move with hit testing, before any event: a read inside a pointer event sees
// them already, as it would a frame later.)
// scripts/check-frame-reads.ts keeps browser tests on these.
import type { Page } from "playwright";

declare global {
  interface Window {
    /** Calls `read` after each painted frame, with that frame's time, until it returns false (an
     *  input event that comes before the read runs it first, on the state the frame painted);
     *  `drive`, if given, runs in each frame's callbacks first (to set what the frame paints, or
     *  note what it paints at). Returns a function that stops it. */
    cmuxAfterPaint: (read: (frame: number) => boolean | void, drive?: (frame: number) => void) => () => void;
    /** Runs `drive` in the next frame's callbacks (as an animation or a fling sets state) and
     *  resolves with that frame's time once the frame has painted. */
    cmuxPaintFrame: (drive?: (frame: number) => void) => Promise<number>;
  }
}

/** The page side; runs in the page, so it closes over nothing. */
function definePaintedFrames() {
  if (typeof window.cmuxAfterPaint === "function") return;
  // Reads of painted frames not yet run: the next input event runs them before it changes anything.
  const pending = new Set<() => void>();
  const flush = () => [...pending].forEach((run) => run());
  // `document.open` (Playwright's setContent) drops the window's listeners and keeps the window's
  // properties: each loop checks that the listeners still hear, and adds them again if not. The
  // window's capture runs before every handler on the document and its elements; only a page's own
  // window capture listener added before these runs first.
  let heard = false;
  const listen = () => {
    heard = false;
    dispatchEvent(new Event("cmux-painted-frames"));
    if (heard) return;
    addEventListener("cmux-painted-frames", () => (heard = true));
    for (const kind of [
      "keydown",
      "keyup",
      "beforeinput",
      "input",
      "compositionupdate",
      "pointerdown",
      "pointerover",
      "pointerout",
      "pointermove",
      "pointerup",
      "mousedown",
      "mouseover",
      "mouseout",
      "mousemove",
      "mouseup",
      "wheel",
      "touchstart",
      "touchmove",
      "touchend",
    ])
      addEventListener(kind, flush, { capture: true, passive: true });
  };
  listen();
  const afterThisFrame = (then: () => void) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => {
      channel.port1.close();
      then();
    };
    channel.port2.postMessage(null);
  };
  window.cmuxAfterPaint = (read, drive) => {
    listen();
    let stopped = false;
    // The next frame is asked for in this one's callback, so no frame goes unread. A read runs as
    // the first task after its frame; under heavy load Chromium can start the next frame first.
    const tick = (frame: number) => {
      if (stopped) return;
      requestAnimationFrame(tick);
      drive?.(frame);
      const run = () => {
        if (!pending.delete(run)) return;
        if (!stopped && read(frame) === false) stopped = true;
      };
      pending.add(run);
      afterThisFrame(run);
    };
    requestAnimationFrame(tick);
    return () => {
      stopped = true;
    };
  };
  window.cmuxPaintFrame = (drive) =>
    new Promise((resolve) =>
      requestAnimationFrame((frame) => {
        drive?.(frame);
        afterThisFrame(() => resolve(frame));
      }),
    );
}

/** Defines `window.cmuxAfterPaint` and `window.cmuxPaintFrame` in `page`'s current document and in
 *  every document it opens from now on. */
export async function installPaintedFrames(page: Page) {
  await page.addInitScript(definePaintedFrames);
  await page.evaluate(definePaintedFrames);
}
