import { expect, test } from "bun:test";
import { Effect, Fiber, TestClock, TestContext } from "effect";
import { FreestyleApiError } from "freestyle";
import { ProviderError } from "../services/vms/drivers/types";
import { cleanupPrivateLinkResource } from "../scripts/devbox-private-link-cleanup";

const failure = (status: number, code: string) => new ProviderError(
  "freestyle", "deletion failed", new FreestyleApiError(status, { code, message: "provider response" }),
);

test("successful deletion completes without another provider call", async () => {
  let calls = 0;
  await Effect.runPromise(cleanupPrivateLinkResource("VM probe", async () => { calls++; }));
  expect(calls).toBe(1);
});

test("deletion conflicts require a successful provider response before completion", async () => {
  let calls = 0;
  await Effect.runPromise(Effect.gen(function* () {
    const work = yield* Effect.fork(cleanupPrivateLinkResource("VPC probe", async () => {
      if (++calls < 3) throw failure(409, "CONFLICT");
    }));
    yield* TestClock.adjust("1 second");
    yield* Fiber.join(work);
  }).pipe(Effect.provide(TestContext.TestContext)));
  expect(calls).toBe(3);
});

test("a permanent provider refusal is not retried", async () => {
  let calls = 0;
  const outcome = await Effect.runPromise(Effect.gen(function* () {
    const work = yield* Effect.fork(cleanupPrivateLinkResource("tunnel probe", async () => {
      calls++;
      throw failure(403, "FORBIDDEN");
    }));
    yield* TestClock.adjust("15 seconds");
    return yield* Fiber.await(work);
  }).pipe(Effect.provide(TestContext.TestContext)));
  expect(outcome._tag).toBe("Failure");
  expect(calls).toBe(1);
});

test("a stalled provider call fails at the cleanup deadline and cancels its request", async () => {
  let aborted = false;
  const outcome = await Effect.runPromise(Effect.gen(function* () {
    const work = yield* Effect.fork(cleanupPrivateLinkResource("VPC probe", (signal) => new Promise(() => {
      signal.addEventListener("abort", () => { aborted = true; }, { once: true });
    })).pipe(Effect.uninterruptible));
    yield* TestClock.adjust("30 seconds");
    const result = yield* Fiber.poll(work);
    yield* Fiber.interrupt(work);
    return result;
  }).pipe(Effect.provide(TestContext.TestContext)));
  expect(outcome._tag).toBe("Some");
  if (outcome._tag === "Some") expect(outcome.value._tag).toBe("Failure");
  expect(aborted).toBe(true);
});

test("scope interruption still runs resource cleanup", async () => {
  const { Deferred } = await import("effect");
  let calls = 0;
  await Effect.runPromise(Effect.gen(function* () {
    const using = yield* Deferred.make<void>();
    const work = yield* Effect.fork(Effect.scoped(Effect.gen(function* () {
      yield* Effect.acquireRelease(Effect.void, () => cleanupPrivateLinkResource("VM probe", async () => { calls++; }));
      yield* Deferred.succeed(using, undefined);
      yield* Effect.never;
    })));
    yield* Deferred.await(using);
    yield* Fiber.interrupt(work);
  }));
  expect(calls).toBe(1);
});
