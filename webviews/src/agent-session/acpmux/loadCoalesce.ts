// CHAT-LOAD-COALESCE (experiment chat-load-coalesce, off by default): under CPU load the chat pane
// spends its main thread re-rendering the transcript once per display frame (AcpmuxPane's render,
// its commit and the layout effects that read layout, about 40% of a core at 33 records/s with no
// load: replay-under-load.bench.ts `split`). A page whose frames already come late cannot show
// those commits anyway; each one only pushes the next frame further out. This scheduler wraps the
// page's per-frame one (`nextFrame`): while the frame a snapshot waited for came late, the next
// snapshot waits until LOAD_EMIT_MS after the last one drew, so several frames' events land in one
// commit. Once a snapshot's frame comes on time again, snapshots go back to every frame.

type Schedule = (run: () => void) => (() => void) | void;
type Clock = {
  now(): number;
  later(run: () => void, ms: number): unknown;
  clear(handle: unknown): void;
};

/// The least time between two snapshots while the page is behind: about six frames at 60 Hz.
export const LOAD_EMIT_MS = 100;
/// A frame that came this long after it was asked for is late: two display frames at 60 Hz.
export const LATE_MS = 34;
/// On-time frames in a row that end the coalescing.
export const ON_TIME_TO_RECOVER = 3;

const pageClock: Clock = {
  now: () => performance.now(),
  later: (run, ms) => setTimeout(run, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export function coalescedUnderLoad(frame: Schedule, clock: Clock = pageClock): Schedule {
  let drawnAt = Number.NEGATIVE_INFINITY;
  let behind = false;
  let onTime = 0;
  return (run) => {
    let done = false;
    let timer: unknown;
    let stopFrame: (() => void) | undefined;
    const ask = () => {
      timer = undefined;
      if (done) return;
      const asked = clock.now();
      stopFrame =
        frame(() => {
          if (done) return;
          done = true;
          const at = clock.now();
          if (at - asked >= LATE_MS) {
            behind = true;
            onTime = 0;
          } else if (behind && ++onTime >= ON_TIME_TO_RECOVER) behind = false;
          drawnAt = at;
          run();
        }) ?? undefined;
    };
    const wait = behind ? drawnAt + LOAD_EMIT_MS - clock.now() : 0;
    if (wait > 0) timer = clock.later(ask, wait);
    else ask();
    return () => {
      done = true;
      if (timer !== undefined) clock.clear(timer);
      stopFrame?.();
    };
  };
}
