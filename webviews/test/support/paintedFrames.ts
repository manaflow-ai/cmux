// Frame tests read what the page painted, once per frame, after that frame's rendering.
//
// A requestAnimationFrame callback runs before the frame's style, layout, ResizeObserver callbacks
// and paint. A read there sees the layout as it stands before the observers that size the page
// (the transcript's room under its last row, for one) have run, a state the frame may never paint:
// a probe read in a frame callback showed the last row 30 px low on the first frame of an opened
// chat, and nobody saw it (scroll-jitter, 2026-10-21). A message posted from the frame callback
// runs as a task after the frame has rendered, so every read here is of a painted state. The
// browser runs queued input before that task, though: a key, a pointer or a wheel event handled
// in between changes the page the read would lay out, a state no frame painted (a composer card a
// line taller than the lift its frame painted, scroll-jitter 2026-10-21). That frame's read is
// skipped. scripts/check-frame-reads.ts keeps browser tests on these.
import type { Page } from "playwright";

declare global {
  interface Window {
    /** Calls `read` after each painted frame, with that frame's time, until it returns false (a
     *  frame whose page input changed before the read is not read);
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
  // Input handled since a frame: one count for every kind the browser runs ahead of tasks.
  let inputs = 0;
  for (const kind of [
    "keydown",
    "keyup",
    "beforeinput",
    "input",
    "compositionupdate",
    "pointerdown",
    "pointermove",
    "pointerup",
    "mousedown",
    "mousemove",
    "mouseup",
    "wheel",
    "touchstart",
    "touchmove",
    "touchend",
  ])
    addEventListener(kind, () => (inputs += 1), { capture: true, passive: true });
  const afterThisFrame = (then: () => void) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => {
      channel.port1.close();
      then();
    };
    channel.port2.postMessage(null);
  };
  window.cmuxAfterPaint = (read, drive) => {
    let stopped = false;
    // The next frame is asked for in this one's callback, so no frame goes unread. A read runs as
    // the first task after its frame; under heavy load Chromium can start the next frame first.
    const tick = (frame: number) => {
      if (stopped) return;
      requestAnimationFrame(tick);
      drive?.(frame);
      const painted = inputs;
      afterThisFrame(() => {
        if (!stopped && inputs === painted && read(frame) === false) stopped = true;
      });
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
