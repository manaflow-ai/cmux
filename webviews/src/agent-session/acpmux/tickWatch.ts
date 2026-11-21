// The transcript's frames while real wheel input scrolls it (`debug.agent_pane tick_watch`): the
// real-app counterpart of webviews/bench/wheel-tick-scaling.bench.ts, for the scroll Leo feels
// (2026-11-07: "I do one tick up, one tick down ... it doesn't jolt as, like, the jumpy sort of
// spry, springy feel"). A bench starts it, posts native scroll events at the page
// (`debug.mouse` `target: "page"`, `action: "scroll"`), then stops it and reads:
//   - each animation frame's interval (the display's cadence: a dropped frame is a long interval)
//     and its work, from the frame's start until the page has rendered it;
//   - the wheel events the page saw, and how many wheelGlide.ts takes as a notch (it eases those
//     itself; other input scrolls natively);
//   - the page's own writes to the transcript's offset during the input (an anchor or follow
//     correction while the reader scrolls, which can jolt a native scroll) and the largest move.
// The watch ends itself after MAX_MS, so a bench that never stops it leaves nothing running.
import { acpmuxPerf, frameStats, median, round2, summary } from "./perf";
import { isWheelNotch } from "./wheelGlide";

const MAX_MS = 120_000;
/// A write counts as the page's during input when a wheel event came this recently.
const INPUT_MS = 200;

type Watch = {
  scroller: HTMLElement;
  started: number;
  timestamps: number[];
  work: number[];
  wheels: number;
  notches: number;
  writes: number;
  writeMax: number;
  moved: number;
  lastWheel: number;
  stop: () => void;
};

let watch: Watch | undefined;

/// `stop` ends the watch and returns its frames; `nominal_ms` is the display's frame interval a dropped
/// frame is counted against (default: the median interval the watch saw).
export function tickWatch(options: { stop?: boolean; nominal_ms?: number } = {}): Record<string, unknown> {
  if (options.stop) return finish(options.nominal_ms);
  finish();
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return { error: "no transcript" };
  acpmuxPerf.enable();
  acpmuxPerf.resetFrames();
  const offset = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
  const now = performance.now();
  const current: Watch = {
    scroller,
    started: now,
    timestamps: [],
    work: [],
    wheels: 0,
    notches: 0,
    writes: 0,
    writeMax: 0,
    moved: 0,
    lastWheel: Number.NEGATIVE_INFINITY,
    stop: () => {},
  };
  const onWheel = (event: WheelEvent) => {
    current.lastWheel = performance.now();
    current.wheels += 1;
    if (isWheelNotch(event)) current.notches += 1;
  };
  scroller.addEventListener("wheel", onWheel, { capture: true, passive: true });
  // The scroller's own offset setter, for this watch only: every write still goes to the element.
  Object.defineProperty(scroller, "scrollTop", {
    configurable: true,
    get() {
      return offset.get!.call(this);
    },
    set(value: number) {
      const before = offset.get!.call(this) as number;
      offset.set!.call(this, value);
      if (performance.now() - current.lastWheel > INPUT_MS) return;
      current.writes += 1;
      current.writeMax = Math.max(current.writeMax, Math.abs((offset.get!.call(this) as number) - before));
    },
  });
  let frame = 0;
  let top = offset.get!.call(scroller) as number;
  const channel = new MessageChannel();
  // Each message carries its own frame's start: a late one is never timed from a newer frame.
  channel.port1.onmessage = (event: MessageEvent<number>) => current.work.push(performance.now() - event.data);
  const tick = (time: number) => {
    current.timestamps.push(time);
    // Runs after this frame's rendering update: the frame's work.
    channel.port2.postMessage(time);
    const next = offset.get!.call(scroller) as number;
    if (Math.abs(next - top) >= 0.5) current.moved += 1;
    top = next;
    if (time - current.started > MAX_MS) {
      finish();
      return;
    }
    frame = requestAnimationFrame(tick);
  };
  frame = requestAnimationFrame(tick);
  current.stop = () => {
    cancelAnimationFrame(frame);
    channel.port1.close();
    scroller.removeEventListener("wheel", onWheel, { capture: true });
    delete (scroller as unknown as Record<string, unknown>).scrollTop;
  };
  watch = current;
  return { started: true };
}

function finish(nominal?: number): Record<string, unknown> {
  const done = watch;
  watch = undefined;
  if (!done) return { error: "no watch" };
  done.stop();
  const intervals = done.timestamps.slice(1).map((time, index) => time - done.timestamps[index]!);
  return {
    frames: frameStats(done.timestamps, nominal && nominal > 0 ? nominal : Math.max(1, median(intervals))),
    work: { n: done.work.length, ...summary(done.work) },
    work_over_8ms: done.work.filter((ms) => ms > 1000 / 120).length,
    moved_frames: done.moved,
    wheel_events: done.wheels,
    notch_events: done.notches,
    js_writes: done.writes,
    js_write_max_px: round2(done.writeMax),
    rows: done.scroller.querySelectorAll(".acpmux-row").length,
    scroll_height: done.scroller.scrollHeight,
  };
}
