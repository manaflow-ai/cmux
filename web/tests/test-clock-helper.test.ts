import { expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Fiber from "effect/Fiber";
import { settleOnTestClock } from "./helpers/test-clock";

// TestClock lists pending sleeps newest first, not in time order, so the
// helper must move the clock to the earliest one.
test("settles at the earliest timer when a later one was scheduled after it", async () => {
  const program = Effect.gen(function* () {
    const early = yield* Effect.fork(Effect.sleep("1 second").pipe(Effect.as("early")));
    yield* Effect.yieldNow();
    yield* Effect.fork(Effect.sleep("2000 seconds"));
    yield* Effect.yieldNow();
    return yield* Fiber.join(early);
  });
  const { exit, elapsedMs } = await settleOnTestClock(program, { giveUpAtMs: 1_200_000 });
  expect(exit && Exit.isSuccess(exit) ? exit.value : null).toBe("early");
  expect(elapsedMs).toBe(1_000);
});
