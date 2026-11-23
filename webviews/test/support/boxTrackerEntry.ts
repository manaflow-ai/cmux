// The page side of boxTrackerPage.ts: one tracker at a time, started and stopped by the test.
import { startBoxTracker, type BoxShift } from "../../src/gallery/shift";

let tracker: { stop(): BoxShift } | undefined;
(window as unknown as { cmuxBoxTracker: unknown }).cmuxBoxTracker = {
  start() {
    tracker?.stop();
    tracker = startBoxTracker(document, { restedAtStart: true });
  },
  stop(): BoxShift {
    const shift = tracker!.stop();
    tracker = undefined;
    return shift;
  },
};
