/** The longest a page whose frames stall holds work for its next paint. */
export const AFTER_PAINT_CAP_MS = 100;

/** Runs `run` in a task after the next animation frame, so the frame paints first; in a task at
 * once when frames do not run (a hidden page, a test without `requestAnimationFrame`), and after
 * `AFTER_PAINT_CAP_MS` at most when frames stall. Returns its cancel. */
export function afterNextPaint(run: () => void): () => void {
  const timers: ReturnType<typeof setTimeout>[] = [];
  let frame: number | undefined;
  let done = false;
  const cancel = () => {
    done = true;
    if (frame !== undefined) cancelAnimationFrame(frame);
    for (const timer of timers) clearTimeout(timer);
  };
  const finish = () => {
    if (done) return;
    cancel();
    run();
  };
  const hidden = typeof document !== "undefined" && document.visibilityState === "hidden";
  if (typeof requestAnimationFrame === "undefined" || hidden) timers.push(setTimeout(finish, 0));
  else {
    frame = requestAnimationFrame(() => {
      frame = undefined;
      timers.push(setTimeout(finish, 0));
    });
    timers.push(setTimeout(finish, AFTER_PAINT_CAP_MS));
  }
  return cancel;
}
