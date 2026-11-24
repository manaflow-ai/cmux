/// A trailing timer: `push(ms)` runs `fire` once `ms` pass with no later push, as a clearTimeout and a
/// setTimeout per push do, but with one timer per quiet stretch. A push while the timer waits only moves
/// its deadline; when the timer comes early it waits out the rest. A fling up a long chat pushes a few of
/// these every frame (the scroll lead's reset, the idle place's write, the rail's rest), and the
/// clearTimeout and setTimeout pairs were seconds of a run's main thread (bench/transcript-scroll-up.bench.ts
/// FIXTURE=flat MODE=fling SPLIT=1: clearTimeout and setTimeout self time).
export type TrailingTimer = {
  push(ms: number): void;
  /// Drops the run waiting, if any; the timer that comes for it does nothing.
  cancel(): void;
  /// Drops the run waiting and its timer (an unmount).
  stop(): void;
  /// Whether a run waits.
  readonly pending: boolean;
};

export function trailingTimer(fire: () => void): TrailingTimer {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let due: number | undefined;
  let armedFor = Number.POSITIVE_INFINITY;
  const arm = (ms: number) => {
    armedFor = Date.now() + ms;
    timer = setTimeout(come, ms);
  };
  const come = () => {
    timer = undefined;
    armedFor = Number.POSITIVE_INFINITY;
    if (due === undefined) return;
    const left = due - Date.now();
    if (left > 0) return arm(left);
    due = undefined;
    fire();
  };
  return {
    push(ms) {
      due = Date.now() + ms;
      if (timer !== undefined && armedFor <= due) return;
      if (timer !== undefined) clearTimeout(timer);
      arm(ms);
    },
    cancel() {
      due = undefined;
    },
    stop() {
      due = undefined;
      if (timer !== undefined) clearTimeout(timer);
      timer = undefined;
      armedFor = Number.POSITIVE_INFINITY;
    },
    get pending() {
      return due !== undefined;
    },
  };
}
