// A page clock that always reads one time and never ticks (pageClock.ts): the clock a static render,
// a test or a gallery fixture passes to a label that reads the time (useNow, useElapsedNow).

import { PageLifecycle } from "../pages/shared/pageLifecycle";
import { PageClock } from "./pageClock";

/** A clock that reads `time` (epoch milliseconds) and schedules nothing. */
export function fixedPageClock(time: number): PageClock {
  return new PageClock(new PageLifecycle(undefined), {
    now: () => time,
    after: () => undefined,
    cancel: () => undefined,
  });
}
