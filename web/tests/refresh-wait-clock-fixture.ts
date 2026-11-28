import type { RefreshWaitClock } from "../services/coderouter/refreshSignal";

type PendingSleep = {
  readonly at: number;
  readonly resolve: () => void;
};

/**
 * Deterministic clock for refresh-completion waits. Time moves only when a
 * test calls `advanceToNextSleep` or `runUntilSettled`, so no test depends on
 * wall time.
 */
export type FakeRefreshWaitClock = RefreshWaitClock & {
  readonly pendingSleeps: () => number;
  readonly advanceToNextSleep: () => boolean;
  readonly runUntilSettled: <T>(promise: Promise<T>) => Promise<T>;
};

export function createFakeRefreshWaitClock(): FakeRefreshWaitClock {
  let now = 0;
  const sleeps = new Set<PendingSleep>();

  // Let non-timer work (mocked I/O, stream setup) run to its next clock wait.
  // Event-loop turns are not timing: the fake clock never reads wall time.
  const flushMicrotasks = async () => {
    for (let index = 0; index < 5; index += 1) {
      await new Promise<void>((resolve) => setImmediate(resolve));
    }
  };

  const advanceToNextSleep = () => {
    let next: PendingSleep | undefined;
    for (const sleep of sleeps) {
      if (!next || sleep.at < next.at) next = sleep;
    }
    if (!next) return false;
    sleeps.delete(next);
    now = Math.max(now, next.at);
    next.resolve();
    return true;
  };

  return {
    now: () => now,
    sleep: (ms, signal) => new Promise<void>((resolve, reject) => {
      if (signal.aborted) {
        reject(signal.reason);
        return;
      }
      const abort = () => {
        sleeps.delete(entry);
        reject(signal.reason);
      };
      const entry: PendingSleep = {
        at: now + ms,
        resolve: () => {
          signal.removeEventListener("abort", abort);
          resolve();
        },
      };
      sleeps.add(entry);
      signal.addEventListener("abort", abort, { once: true });
    }),
    pendingSleeps: () => sleeps.size,
    advanceToNextSleep,
    runUntilSettled: async <T>(promise: Promise<T>) => {
      let settled = false;
      const observed = promise.then(
        (value) => {
          settled = true;
          return value;
        },
        (error: unknown) => {
          settled = true;
          throw error;
        },
      );
      observed.catch(() => undefined);
      for (let step = 0; step < 1_000 && !settled; step += 1) {
        await flushMicrotasks();
        if (!settled) advanceToNextSleep();
      }
      if (!settled) throw new Error("fake clock gave up while the awaited promise is still pending");
      return await observed;
    },
  };
}
