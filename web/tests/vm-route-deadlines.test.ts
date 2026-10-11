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
import { VM_ROUTE_DEADLINES, vmClientTimeoutMsFromRequest, withVmAnswerDeadline, withVmRouteDeadline, type VmRouteDeadlineOperation } from "../services/vms/routeDeadline";

// Production 2026-10-11: pause, exec and scp-endpoint each waited 2-4 minutes
// on a Freestyle background request that then failed 502, long after the
// client gave up. Every provider-bound VM route now answers inside its
// client's budget, and a mutation that may still finish says so.

/** Runs `program` under the route deadline on the test clock; returns the failure and the virtual time. */
async function underDeadline(operation: VmRouteDeadlineOperation, program: Effect.Effect<string, VmWorkflowError>, elapsedMs = 0, clientTimeoutMs?: number) {
  const background: Promise<unknown>[] = [];
  const result = await Effect.runPromise(Effect.gen(function* () {
    const fiber = yield* Effect.fork(withVmRouteDeadline(program, {
      operation, elapsedMs, ...(clientTimeoutMs === undefined ? {} : { clientTimeoutMs }), continueInBackground: (work) => { background.push(work); },
    }).pipe(Effect.either));
    let virtualMs = 0;
    while (Option.isNone(yield* Fiber.poll(fiber)) && virtualMs < 900_000) {
      yield* TestClock.adjust(250);
      virtualMs += 250;
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

  test("a read that never answers is a provider timeout at its client's budget", async () => {
    const { answer, virtualMs } = await underDeadline("stats", Effect.never);
    expect(virtualMs).toBeLessThanOrEqual(VM_ROUTE_DEADLINES.stats.clientTimeoutMs - 5_000 + 250);
    const error = answer?._tag === "Left" ? answer.left as VmOperationDeadlineError : null;
    expect(error?._tag).toBe("VmOperationDeadlineError");
    expect(error?.mutating).toBe(false);
  });

  test("a read keeps a provider failure that arrives before the deadline", async () => {
    const failed = providerFailure("getStats", new ProviderError("freestyle", "getStats", gateway502()));
    const { answer } = await underDeadline("stats", Effect.fail(failed));
    expect(answer?._tag === "Left" ? answer.left : null).toBe(failed);
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
    const capped = await underDeadline("stats", Effect.never, 0, 3_600_000);
    expect(capped.virtualMs).toBeLessThanOrEqual(VM_ROUTE_DEADLINES.stats.maxDurationMs - 5_000 + 250);
    expect(capped.virtualMs).toBeGreaterThanOrEqual(VM_ROUTE_DEADLINES.stats.maxDurationMs - 5_000);
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
