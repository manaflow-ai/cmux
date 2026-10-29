import * as Chunk from "effect/Chunk";
import * as Effect from "effect/Effect";
import type * as Exit from "effect/Exit";
import * as Fiber from "effect/Fiber";
import * as Option from "effect/Option";
import * as TestClock from "effect/TestClock";
import * as TestContext from "effect/TestContext";

/** Real event-loop turns allowed with no timer pending before the program is treated as stuck. */
const IDLE_TURNS = 200;

/**
 * Runs `program` on the test clock until it settles, jumping the clock
 * straight to each pending timer instead of stepping through time. Returns its
 * exit (null if it had not settled by `giveUpAtMs`) and the virtual time it
 * settled at, which is exact. Real time stays a few event-loop turns however
 * long the virtual wait is, so these tests fit Bun's 5 s limit on a loaded CI
 * runner; stepping a 955 s budget in small increments did not.
 */
export function settleOnTestClock<A, E>(
  program: Effect.Effect<A, E>,
  options: { readonly giveUpAtMs?: number } = {},
): Promise<{ readonly exit: Exit.Exit<A, E> | null; readonly elapsedMs: number }> {
  const giveUpAtMs = options.giveUpAtMs ?? Number.POSITIVE_INFINITY;
  return Effect.runPromise(Effect.gen(function* () {
    const fiber = yield* Effect.fork(program);
    let idleTurns = 0;
    while (Option.isNone(yield* Fiber.poll(fiber))) {
      // Let promise-based work settle before reading the pending timers.
      yield* Effect.promise(() => new Promise<void>((resolve) => setImmediate(resolve)));
      if (Option.isSome(yield* Fiber.poll(fiber))) break;
      // TestClock lists pending sleeps newest first, not in time order.
      const pending = Chunk.toReadonlyArray(yield* TestClock.sleeps());
      if (pending.length === 0) {
        if (++idleTurns > IDLE_TURNS) break;
        continue;
      }
      const next = Math.min(...pending);
      if (next > giveUpAtMs) break;
      idleTurns = 0;
      yield* TestClock.setTime(next);
    }
    const elapsedMs = yield* TestClock.currentTimeMillis;
    const done = yield* Fiber.poll(fiber);
    if (Option.isNone(done)) {
      yield* Fiber.interrupt(fiber);
      return { exit: null, elapsedMs };
    }
    return { exit: done.value, elapsedMs };
  }).pipe(Effect.provide(TestContext.TestContext)));
}
