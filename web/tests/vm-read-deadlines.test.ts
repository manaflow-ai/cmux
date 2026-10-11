import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Option from "effect/Option";
import * as TestClock from "effect/TestClock";
import * as TestContext from "effect/TestContext";
import { ProviderError } from "../services/vms/drivers/types";
import { VmOperationDeadlineError, VmProviderOperationError, type VmWorkflowError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { VM_READ_ROUTE_DEADLINES, withVmReadDeadline, type VmReadRouteOperation } from "../services/vms/routeDeadline";

// Production 2026-10-11: GET /api/vm/[id]/stats and other reads waited on a
// hung provider call long after the Mac client (30 s) gave up. A read now
// answers inside its client's budget. Stage A of the reland after #19467:
// the deadline is inline. The provider call is interrupted at the budget,
// nothing is forked, nothing continues after the response.

/** Runs `program` under the read deadline on the test clock. */
async function underReadDeadline<A>(operation: VmReadRouteOperation, program: Effect.Effect<A, VmWorkflowError>, elapsedMs = 0, stepMs = 250) {
  return await Effect.runPromise(Effect.gen(function* () {
    const fiber = yield* Effect.fork(withVmReadDeadline(program, { operation, elapsedMs }).pipe(Effect.either));
    let virtualMs = 0;
    while (Option.isNone(yield* Fiber.poll(fiber)) && virtualMs < 300_000) {
      yield* TestClock.adjust(stepMs);
      virtualMs += stepMs;
      yield* Effect.promise(() => new Promise<void>((resolve) => setImmediate(resolve)));
    }
    const answer = yield* Fiber.poll(fiber);
    if (Option.isNone(answer)) {
      yield* Fiber.interrupt(fiber);
      return { answer: null, virtualMs };
    }
    return { answer: yield* Fiber.join(fiber), virtualMs };
  }).pipe(Effect.provide(TestContext.TestContext)));
}

const budgets: Array<[VmReadRouteOperation, number]> = [
  ["stats", 25_000],
  ["networkRead", 25_000],
  ["snapshotList", 55_000],
  ["getVm", 55_000],
  ["filesRead", 55_000],
  ["tunnelRead", 55_000],
];

describe("VM read deadlines", () => {
  test.each(budgets)("%s answers a provider timeout at %i ms and interrupts the provider call", async (operation, budgetMs) => {
    let interrupted = false;
    const hung = Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => { interrupted = true; })));
    const { answer, virtualMs } = await underReadDeadline(operation, hung as Effect.Effect<string, VmWorkflowError>);
    expect(virtualMs).toBeGreaterThanOrEqual(budgetMs);
    expect(virtualMs).toBeLessThanOrEqual(budgetMs + 250);
    const error = answer?._tag === "Left" ? answer.left : null;
    expect(error).toBeInstanceOf(VmOperationDeadlineError);
    expect((error as VmOperationDeadlineError).mutating).toBe(false);
    // Inline: the provider call is stopped at the answer, nothing runs on.
    expect(interrupted).toBe(true);
  });

  test("a provider failure before the deadline keeps its own error", async () => {
    const failed = new VmProviderOperationError({ provider: "freestyle", operation: "getStats", cause: new ProviderError("freestyle", "getStats") });
    const { answer } = await underReadDeadline("stats", Effect.fail(failed));
    expect(answer?._tag === "Left" ? answer.left : null).toBe(failed);
  });

  test("a finished read answers its value", async () => {
    const { answer } = await underReadDeadline("stats", Effect.succeed("awake"));
    expect(answer?._tag === "Right" ? answer.right : null).toBe("awake");
  });

  test("the window is measured from the request's start, with a 10 s floor", async () => {
    expect((await underReadDeadline("stats", Effect.never, 5_000)).virtualMs).toBeLessThanOrEqual(20_250);
    expect((await underReadDeadline("stats", Effect.never, 60_000)).virtualMs).toBeLessThanOrEqual(10_250);
  });

  test("every legacy budget leaves the client 5 s", () => {
    expect(VM_READ_ROUTE_DEADLINES.stats.clientTimeoutMs - 5_000).toBe(25_000);
  });
});

describe("concurrent reads share nothing", () => {
  // The real helper and runtime with many requests in flight at once: hung
  // reads time out on their own budgets, the others answer their own values
  // as soon as their provider answers, and no request sees another's result.
  test("hung reads do not delay or cross other reads", async () => {
    const results = await Effect.runPromise(Effect.gen(function* () {
      const fibers = yield* Effect.forEach(Array.from({ length: 60 }, (_, index) => index), (index) => Effect.fork(
        withVmReadDeadline(
          index % 3 === 0
            ? (Effect.never as Effect.Effect<string, VmWorkflowError>)
            : Effect.sleep(`${100 + index} millis`).pipe(Effect.as(`vm-${index}`)),
          { operation: "stats", elapsedMs: 0 },
        ).pipe(Effect.either),
      ));
      // The answering reads finish within a second of virtual time.
      yield* TestClock.adjust(1_000);
      const early = yield* Effect.forEach(fibers, (fiber) => Fiber.poll(fiber));
      yield* TestClock.adjust(25_000);
      const late = yield* Effect.forEach(fibers, (fiber) => Fiber.join(fiber));
      return { early, late };
    }).pipe(Effect.provide(TestContext.TestContext)));
    results.late.forEach((answer, index) => {
      if (index % 3 === 0) {
        expect(answer._tag).toBe("Left");
      } else {
        expect(answer._tag === "Right" ? answer.right : null).toBe(`vm-${index}`);
        expect(Option.isSome(results.early[index])).toBe(true);
      }
    });
  });
});

describe("VM read deadline answer", () => {
  test("a read past its deadline answers a retryable 504 provider timeout", async () => {
    const response = await vmWorkflowErrorResponse(new VmOperationDeadlineError({ operation: "stats", mutating: false, waitedMs: 25_000 }));
    expect(response?.status).toBe(504);
    const payload = await response!.json() as Record<string, unknown>;
    expect(payload).toMatchObject({ error: "vm_provider_timeout", retryable: true });
    expect(JSON.stringify(payload)).not.toMatch(/temporarily unavailable/i);
  });
});
