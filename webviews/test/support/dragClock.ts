// The clock of a pane drag that a test drives in a real browser (transcriptDragStays.ts,
// transcriptDragFlows.ts): one new width each frame.
//
// The transcript reads a width that comes inside 120 ms of the last one as a live resize, and a
// timer ends it 120 ms after the last width. On the runner's own clock a slow frame (a step gap of
// 99 ms was seen in CI) is close to ending the drag in its middle, and the test would then read
// another motion than the one it names. So from the first width step until the drag's own timers
// ran, `performance.now` and the timers that the page sets go by a clock that gains a fixed step
// each frame: each width is one frame after the one before on any runner, and the live resize ends
// when the test's clock says so. Frames, layout, observers and the rows are the browser's own; no
// product code is changed for this.
//
// A page function cannot import (Playwright sends its text to the page), so the clock is put on
// the page first (`page.evaluate(installDragClock)`) and the drag's page function takes one from
// `window.dragClock`.

/** One drag's clock. */
export type DragClock = {
  /** The browser's own clock, ms, also while the drag's clock runs. */
  pageNow: () => number;
  /** From now on the page reads the drag's clock, and the timers it sets wait for that clock. */
  start: () => void;
  /** One frame's time passes, and the timers due in it run in their order, as tasks between frames. */
  advance: () => void;
  /** The page's clock is its own again, never back in time. */
  end: () => Promise<void>;
};
/** What `installDragClock` puts on the page's window. */
export type DragClockWindow = {
  /** A new clock that gains `clockStep` ms each time it advances. */
  dragClock?: (clockStep: number) => DragClock;
  /** The last id a held timer got: keeps the ids apart for each drag in one page. */
  heldTimerIds?: number;
};

/// Runs in the page, before a drag's own page function.
export function installDragClock(): void {
  const host = window as unknown as DragClockWindow;
  host.dragClock = (clockStep) => {
    const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
    const pageNow = () => Performance.prototype.now.call(performance);
    const pageSetTimeout = window.setTimeout;
    const pageClearTimeout = window.clearTimeout;
    // Timers set while the clock runs wait in `held` with a negative id, which no browser timer has.
    type Held = { id: number; due: number; run: () => void };
    let clock = 0;
    let held: Held[] = [];
    /// The ids of held timers that went back to the browser when the drag's clock ended.
    const handedBack = new Map<number, number>();
    const start = () => {
      clock = pageNow();
      performance.now = () => clock;
      window.setTimeout = ((handler: TimerHandler, delay?: number, ...args: unknown[]) => {
        const id = (host.heldTimerIds ?? 0) - 1;
        host.heldTimerIds = id;
        held.push({
          id,
          due: clock + Math.max(0, Number(delay) || 0),
          run: () => {
            if (typeof handler === "function") handler(...args);
          },
        });
        return id;
      }) as typeof window.setTimeout;
      // Stays for the page's life: a timer handed back (`end`) keeps the id that its owner has.
      window.clearTimeout = ((id?: number) => {
        held = held.filter((timer) => timer.id !== id);
        // The browser's id of a timer handed back; else an id of the browser's, or of an earlier drag
        // in this page, which the `clearTimeout` before this one knows.
        pageClearTimeout.call(window, (typeof id === "number" ? handedBack.get(id) : undefined) ?? id);
      }) as typeof window.clearTimeout;
    };
    const advance = () => {
      clock += clockStep;
      for (let count = 0; count < 1000; count += 1) {
        const due = held.filter((timer) => timer.due <= clock).sort((a, b) => a.due - b.due || b.id - a.id)[0];
        if (!due) return;
        held = held.filter((timer) => timer !== due);
        try {
          due.run();
        } catch (error) {
          // Not this test's error to hide: it goes to the page as a timer's error does.
          pageSetTimeout.call(window, () => {
            throw error;
          });
        }
      }
    };
    /// A timer still held (one longer than the drag) goes to the browser with the time it has left,
    /// and its id stays known to `clearTimeout`.
    const end = async () => {
      while (pageNow() < clock) await frame();
      Reflect.deleteProperty(performance, "now");
      window.setTimeout = pageSetTimeout;
      for (const timer of held) {
        // In the page the browser's id is a number (the test file's own types name Bun's timer).
        handedBack.set(timer.id, Number(pageSetTimeout.call(window, timer.run, Math.max(0, timer.due - clock))));
      }
      held = [];
    };
    return { pageNow, start, advance, end };
  };
}
