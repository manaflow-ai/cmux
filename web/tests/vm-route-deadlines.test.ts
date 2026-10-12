import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Option from "effect/Option";
import * as TestClock from "effect/TestClock";
import * as TestContext from "effect/TestContext";
import { FreestyleApiError, type Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { ProviderError, ProviderGuestUnresponsiveError } from "../services/vms/drivers/types";
import { VmOperationDeadlineError, VmProviderOperationError, type VmWorkflowError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { VM_CREATE_RESERVE_AFTER_ANSWER_MS, VM_MAX_BACKGROUND_CONTINUATIONS, VM_ROUTE_DEADLINES, backgroundContinuations, vmClientTimeoutMsFromRequest, vmRouteDeadlinePlan, withVmAnswerDeadline, withVmRouteDeadline, type VmRouteDeadlineOperation } from "../services/vms/routeDeadline";

// Production 2026-10-11: pause, exec and scp-endpoint each waited 2-4 minutes
// on a Freestyle background request that then failed 502, long after the
// client gave up. Every provider-bound VM route now answers inside its
// client's budget, and a mutation that may still finish says so.

/** Runs `program` under the route deadline on the test clock; returns the failure and the virtual time. */
async function underDeadline(operation: VmRouteDeadlineOperation, program: Effect.Effect<string, VmWorkflowError>, elapsedMs = 0, clientTimeoutMs?: number, stepMs = 250) {
  const background: Promise<unknown>[] = [];
  const result = await Effect.runPromise(Effect.gen(function* () {
    const fiber = yield* Effect.fork(withVmRouteDeadline(program, {
      operation, elapsedMs, ...(clientTimeoutMs === undefined ? {} : { clientTimeoutMs }), continueInBackground: (work) => { background.push(work); },
    }).pipe(Effect.either));
    let virtualMs = 0;
    while (Option.isNone(yield* Fiber.poll(fiber)) && virtualMs < 1_200_000) {
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
  return { ...result, background };
}

const providerFailure = (operation: string, cause: unknown) =>
  new VmProviderOperationError({ provider: "freestyle", operation, cause });

const gateway502 = () => Object.assign(new Error("Bad Gateway"), { name: "FreestyleApiError", status: 502, code: "INTERNAL_ERROR" });
const early401 = () => Object.assign(new Error("invalid api key"), { name: "FreestyleApiError", status: 401, code: "UNAUTHORIZED" });

describe("VM route answer deadlines", () => {
  test("a mutation that never answers is in progress at its client's budget, and keeps running", async () => {
    const { answer, virtualMs, background } = await underDeadline("pause", Effect.never);
    const budgetMs = VM_ROUTE_DEADLINES.pause.clientTimeoutMs - 5_000;
    expect(virtualMs).toBeGreaterThanOrEqual(budgetMs);
    expect(virtualMs).toBeLessThanOrEqual(budgetMs + 250);
    expect(answer?._tag).toBe("Left");
    const error = answer?._tag === "Left" ? answer.left : null;
    expect(error).toBeInstanceOf(VmOperationDeadlineError);
    expect((error as VmOperationDeadlineError).mutating).toBe(true);
    expect(background).toHaveLength(1);
  });

  test("a mutation whose provider call hangs into a gateway 502 answers in progress", async () => {
    const { answer, virtualMs } = await underDeadline(
      "pause",
      Effect.fail(providerFailure("pause", new ProviderError("freestyle", "pause", gateway502()))),
    );
    expect(virtualMs).toBeLessThan(5_000);
    const error = answer?._tag === "Left" ? answer.left : null;
    expect(error?._tag).toBe("VmOperationDeadlineError");
  });

  test("an early provider refusal keeps its own error", async () => {
    const refused = providerFailure("destroy", new ProviderError("freestyle", "destroy", early401()));
    const { answer } = await underDeadline("destroy", Effect.fail(refused));
    expect(answer?._tag === "Left" ? answer.left : null).toBe(refused);
  });

  test("a finished operation answers its value", async () => {
    const { answer, background } = await underDeadline("resume", Effect.succeed("running"));
    expect(answer?._tag === "Right" ? answer.right : null).toBe("running");
    expect(background).toHaveLength(0);
  });

  test("the window is measured from the request's start, with a floor", async () => {
    const late = await underDeadline("resize", Effect.never, 200_000);
    expect(late.virtualMs).toBeLessThanOrEqual(10_250);
    const early = await underDeadline("resize", Effect.never, 30_000);
    expect(early.virtualMs).toBeLessThanOrEqual(VM_ROUTE_DEADLINES.resize.clientTimeoutMs - 5_000 - 30_000 + 250);
    expect(early.virtualMs).toBeGreaterThan(70_000);
  });
});

// The remaining provider-bound mutations: rename, private network enrollment
// (190 s worst case in production) and revoke, attach, session open and
// create. Each answers inside its legacy caller's budget when the client
// states none, and a create still running answers in progress.
describe("remaining VM routes", () => {
  const expected: Array<[VmRouteDeadlineOperation, number, boolean]> = [
    ["rename", 55_000, true],
    ["tunnelEnroll", 55_000, true],
    ["tunnelRevoke", 15_000, true],
    ["attach", 955_000, true],
    ["sessionOpen", 955_000, true],
    // A create answers early enough to keep its whole provider deadline:
    // "in progress" is then true (it ends running, or failed and refunded).
    ["create", 25_000, true],
  ];
  test.each(expected)("%s answers at %i ms (mutating %p) when the provider never answers", async (operation, budgetMs, mutating) => {
    const { answer, virtualMs, background } = await underDeadline(operation, Effect.never, 0, undefined, 1_000);
    expect(virtualMs).toBeGreaterThanOrEqual(budgetMs);
    expect(virtualMs).toBeLessThanOrEqual(budgetMs + 1_000);
    const error = answer?._tag === "Left" ? answer.left as VmOperationDeadlineError : null;
    expect(error?._tag).toBe("VmOperationDeadlineError");
    expect(error?.mutating).toBe(mutating);
    // Work continues in the background only while the route's maxDuration
    // leaves time for it; a budget that reaches maxDuration leaves none.
    const continues = VM_ROUTE_DEADLINES[operation].maxDurationMs - 5_000 - budgetMs > 0;
    expect(background).toHaveLength(continues ? 1 : 0);
  });

  test("a create answered in progress keeps its whole provider deadline before maxDuration", () => {
    for (const elapsedMs of [0, 1_000, 24_000, 40_000]) {
      for (const clientTimeoutMs of [undefined, 15_000, 120_000, 960_000]) {
        const plan = vmRouteDeadlinePlan("create", { elapsedMs, clientTimeoutMs });
        expect(plan.continueForMs).toBeGreaterThanOrEqual(VM_CREATE_RESERVE_AFTER_ANSWER_MS - Math.max(0, elapsedMs - 25_000));
        expect(elapsedMs + plan.answerWithinMs + plan.continueForMs).toBeLessThanOrEqual(VM_ROUTE_DEADLINES.create.maxDurationMs - 5_000);
      }
    }
    // Inside the first 25 s the reserve is whole.
    expect(vmRouteDeadlinePlan("create", { elapsedMs: 2_000 }).continueForMs).toBeGreaterThanOrEqual(VM_CREATE_RESERVE_AFTER_ANSWER_MS);
  });

  test("a create without an Idempotency-Key ignores a shorter stated budget", async () => {
    const keyed = await underDeadline("create", Effect.never, 0, 15_000, 1_000);
    expect(keyed.virtualMs).toBeLessThanOrEqual(10_000);
    const background: Promise<unknown>[] = [];
    const unkeyed = await Effect.runPromise(Effect.gen(function* () {
      const fiber = yield* Effect.fork(withVmRouteDeadline(Effect.never as Effect.Effect<string, VmWorkflowError>, {
        operation: "create", elapsedMs: 0, clientTimeoutMs: 15_000, ignoreClientBudget: true,
        continueInBackground: (work) => { background.push(work); },
      }).pipe(Effect.either));
      let virtualMs = 0;
      while (Option.isNone(yield* Fiber.poll(fiber)) && virtualMs < 60_000) {
        yield* TestClock.adjust(1_000);
        virtualMs += 1_000;
        yield* Effect.promise(() => new Promise<void>((resolve) => setImmediate(resolve)));
      }
      return virtualMs;
    }).pipe(Effect.provide(TestContext.TestContext)));
    expect(unkeyed).toBeGreaterThanOrEqual(25_000);
  });

  test("a create whose provider hangs into a gateway 502 answers in progress, not an outage", async () => {
    const { answer } = await underDeadline("create", Effect.fail(providerFailure("create", new ProviderError("freestyle", "create", gateway502()))));
    const error = answer?._tag === "Left" ? answer.left : null;
    expect(error?._tag).toBe("VmOperationDeadlineError");
    const response = await vmWorkflowErrorResponse(error);
    expect(response?.status).toBe(503);
    expect(await response!.json()).toMatchObject({ error: "vm_operation_in_progress", phase: "create" });
  });
});

describe("client-stated budgets", () => {
  test("a stated budget replaces the legacy caller's, less the margin", async () => {
    const { virtualMs } = await underDeadline("pause", Effect.never, 0, 120_000);
    expect(virtualMs).toBeGreaterThanOrEqual(115_000);
    expect(virtualMs).toBeLessThanOrEqual(115_250);
  });

  test("the stated budget is read from the client timeout header", () => {
    const stated = (value?: string) => vmClientTimeoutMsFromRequest(new Request("https://cmux.test/api/vm/x/pause", value === undefined ? {} : { headers: { "x-cmux-client-timeout-ms": value } }));
    expect(stated("20000")).toBe(20_000);
    expect(stated()).toBeUndefined();
    expect(stated("abc")).toBeUndefined();
    expect(stated("0")).toBeUndefined();
    expect(stated("-5")).toBeUndefined();
  });

  test("a stated budget is clamped to the 10 s floor and below the route's maxDuration", async () => {
    expect((await underDeadline("pause", Effect.never, 0, 1_000)).virtualMs).toBeLessThanOrEqual(10_250);
    const capped = await underDeadline("pause", Effect.never, 0, 3_600_000, 1_000);
    expect(capped.virtualMs).toBeLessThanOrEqual(VM_ROUTE_DEADLINES.pause.maxDurationMs - 5_000 + 1_000);
    expect(capped.virtualMs).toBeGreaterThanOrEqual(VM_ROUTE_DEADLINES.pause.maxDurationMs - 5_000);
  });
});

describe("stuck guests and background work", () => {
  test("a stuck guest keeps its vm_guest_unresponsive error on a mutating route", async () => {
    const stuck = providerFailure("pause", new ProviderGuestUnresponsiveError("freestyle", "the machine did not answer"));
    const { answer } = await underDeadline("pause", Effect.fail(stuck));
    expect(answer?._tag === "Left" ? answer.left : null).toBe(stuck);
  });

  test("work with nothing to finish is interrupted at the deadline instead of kept alive", async () => {
    let interrupted = false;
    const background: Promise<unknown>[] = [];
    const answer = await Effect.runPromise(Effect.gen(function* () {
      const fiber = yield* Effect.fork(withVmAnswerDeadline(Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => { interrupted = true; }))), {
        answerWithinMs: 1_000, onDeadline: () => Effect.succeed("timed out"), continueForMs: 0, label: "test",
        continueInBackground: (work) => { background.push(work); },
      }));
      yield* TestClock.adjust(1_000);
      return yield* Fiber.join(fiber);
    }).pipe(Effect.provide(TestContext.TestContext)));
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(answer).toBe("timed out");
    expect(background).toHaveLength(0);
    expect(interrupted).toBe(true);
  });

  test("background work is interrupted when its continuation window ends", async () => {
    let interrupted = false;
    const background: Promise<unknown>[] = [];
    await Effect.runPromise(withVmAnswerDeadline(Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => { interrupted = true; }))), {
      answerWithinMs: 5, onDeadline: () => Effect.succeed("in progress"), continueForMs: 20, label: "test",
      continueInBackground: (work) => { background.push(work); },
    }));
    expect(background).toHaveLength(1);
    await background[0];
    expect(interrupted).toBe(true);
  });
});

describe("VM route deadline answers", () => {
  test("a mutation past its deadline answers in progress with a status check, not an outage", async () => {
    const response = await vmWorkflowErrorResponse(new VmOperationDeadlineError({ operation: "pause", mutating: true, waitedMs: 15_000 }));
    expect(response?.status).toBe(503);
    const payload = await response!.json() as Record<string, unknown>;
    expect(payload).toMatchObject({ error: "vm_operation_in_progress", retryable: true });
    expect(String(payload.action)).toContain("cmux vm ls");
    expect(JSON.stringify(payload)).not.toMatch(/temporarily unavailable/i);
  });

  test("a read past its deadline answers a retryable provider timeout", async () => {
    const response = await vmWorkflowErrorResponse(new VmOperationDeadlineError({ operation: "stats", mutating: false, waitedMs: 25_000 }));
    expect(response?.status).toBe(504);
    const payload = await response!.json() as Record<string, unknown>;
    expect(payload).toMatchObject({ error: "vm_provider_timeout", retryable: true });
  });
});

describe("Freestyle raw pause state", () => {
  const providerWith = (get: () => Promise<unknown>) =>
    new FreestyleProvider({ client: () => ({ vms: { get } }) as unknown as Freestyle });

  test.each([
    ["paused", "paused"],
    ["pausing", "in_progress"],
    ["starting", "in_progress"],
    ["running", "not_paused"],
    ["stopped", "not_paused"],
  ])("maps %s to %s", async (state, expected) => {
    expect(await providerWith(async () => ({ state })).getPauseState("vm-1")).toBe(expected);
  });

  test("a machine the provider no longer has is destroyed, not a pause target", async () => {
    const gone = providerWith(async () => { throw new FreestyleApiError(404, { code: "NOT_FOUND", message: "VM not found" }); });
    expect(await gone.getPauseState("vm-1")).toBe("destroyed");
  });

  test("another provider failure stays a provider error", async () => {
    const failing = providerWith(async () => { throw new FreestyleApiError(500, { code: "INTERNAL_ERROR", message: "boom" }); });
    await expect(failing.getPauseState("vm-1")).rejects.toThrow("getPauseState(vm-1)");
  });
});

// Review of #19982: a request past the continuation cap must not answer "in
// progress" for work it would then stop, and a retry of a re-entrant
// operation must not add a second continuation for the same machine.
describe("continuation limits", () => {
  const onTestClock = <A>(program: Effect.Effect<A, string>) => Effect.runPromise(Effect.gen(function* () {
    const fiber = yield* Effect.fork(program.pipe(Effect.either));
    for (let step = 0; step < 40 && Option.isNone(yield* Fiber.poll(fiber)); step += 1) {
      yield* TestClock.adjust(500);
      yield* Effect.promise(() => new Promise<void>((resolve) => setImmediate(resolve)));
    }
    return yield* Fiber.join(fiber);
  }).pipe(Effect.provide(TestContext.TestContext)));

  test("past the cap the request waits for its work inline instead of answering in progress", async () => {
    for (let index = 0; index < VM_MAX_BACKGROUND_CONTINUATIONS; index += 1) backgroundContinuations.tryAcquire();
    try {
      const background: Promise<unknown>[] = [];
      const answer = await onTestClock(withVmAnswerDeadline(
        Effect.sleep("3 seconds").pipe(Effect.as("paused")),
        { answerWithinMs: 1_000, onDeadline: () => Effect.fail("in progress"), continueForMs: 60_000, label: "pause",
          continueInBackground: (work) => { background.push(work); } },
      ));
      expect(answer._tag === "Right" ? answer.right : null).toBe("paused");
      expect(background).toHaveLength(0);
    } finally {
      for (let index = 0; index < VM_MAX_BACKGROUND_CONTINUATIONS; index += 1) backgroundContinuations.release();
    }
  });

  test("a retry for a machine whose attach already continues adds no second continuation", async () => {
    expect(backgroundContinuations.tryAcquire("attach:vm-1")).toBe(true);
    try {
      let interrupted = false;
      const background: Promise<unknown>[] = [];
      const answer = await onTestClock(withVmAnswerDeadline(
        (Effect.never as Effect.Effect<string, string>).pipe(Effect.onInterrupt(() => Effect.sync(() => { interrupted = true; }))),
        { answerWithinMs: 1_000, onDeadline: () => Effect.fail("in progress"), continueForMs: 60_000, label: "attach",
          continuationKey: "attach:vm-1", continueInBackground: (work) => { background.push(work); } },
      ));
      expect(answer._tag).toBe("Left");
      expect(background).toHaveLength(0);
      await new Promise<void>((resolve) => setImmediate(resolve));
      expect(interrupted).toBe(true);
      expect(backgroundContinuations.running).toBe(1);
    } finally {
      backgroundContinuations.release("attach:vm-1");
    }
  });
});

