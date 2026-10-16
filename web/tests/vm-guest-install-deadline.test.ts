import { expect, test } from "bun:test";
import { Deferred, Effect, Fiber, TestClock, TestContext } from "effect";
import { GUEST_INSTALL_DEADLINE_MS, installFreestyleGuestCli } from "../services/vms/drivers/freestyleGuestCli";
import { freestyleGuestFixture } from "./fixtures/freestyleGuest";
import { Freestyle, FreestyleApiError } from "freestyle";
import { rollbackFreestyleCreate } from "../services/vms/drivers/providerCreateCleanup";

test("an active stalled exec is aborted at the overall deadline, then cleaned with a fresh signal", async () => {
  let active = 0;
  let aborted = 0;
  await Effect.runPromise(Effect.gen(function* () {
    const entered = yield* Deferred.make<void>();
    const fixture = freestyleGuestFixture({
      exec: async (_, signal) => {
        active++;
        Effect.runSync(Deferred.succeed(entered, undefined));
        return new Promise<Response>((_, reject) => signal!.addEventListener("abort", () => {
          active--; aborted++; reject(signal!.reason);
        }, { once: true }));
      },
      remove: (_, signal) => { expect(signal?.aborted).toBe(false); expect(active).toBe(0); },
    });
    const work = yield* Effect.fork(Effect.either(installFreestyleGuestCli(fixture.client, "vm-fixture-1")));
    yield* Deferred.await(entered);
    expect(active).toBe(1);
    yield* TestClock.adjust(GUEST_INSTALL_DEADLINE_MS - 1);
    expect((yield* Fiber.poll(work))._tag).toBe("None");
    expect(active).toBe(1);
    yield* TestClock.adjust(1);
    const outcome = yield* Fiber.join(work);
    expect(outcome._tag).toBe("Left");
    if (outcome._tag === "Left") expect(outcome.left).toMatchObject({ outcome: "deadline", stage: "install" });
    expect(active).toBe(0);
    expect(aborted).toBe(1);
    expect(fixture.removals).toEqual(fixture.writes);
  }).pipe(Effect.provide(TestContext.TestContext)));
});

test("cancelling during upload never starts exec and still cleans the upload", async () => {
  let aborted = false;
  await Effect.runPromise(Effect.gen(function* () {
    const entered = yield* Deferred.make<void>();
    const fixture = freestyleGuestFixture({ write: async (_, __, signal) => {
      Effect.runSync(Deferred.succeed(entered, undefined));
      await new Promise<void>((_, reject) => signal!.addEventListener("abort", () => {
        aborted = true; reject(signal!.reason);
      }, { once: true }));
    } });
    const work = yield* Effect.fork(installFreestyleGuestCli(fixture.client, "vm-fixture-1"));
    yield* Deferred.await(entered);
    yield* Fiber.interrupt(work);
    expect(aborted).toBe(true);
    expect(fixture.requests.some(({ path }) => path.endsWith("exec-await"))).toBe(false);
    expect(fixture.removals).toEqual(fixture.writes);
  }));
});

test("a stalled cleanup finalizer is bounded and retains the original install failure", async () => {
  let aborted = false;
  await Effect.runPromise(Effect.gen(function* () {
    const entered = yield* Deferred.make<void>();
    const fixture = freestyleGuestFixture({
      exec: async () => Response.json({ statusCode: 124 }),
      remove: async (_, signal) => {
        Effect.runSync(Deferred.succeed(entered, undefined));
        await new Promise<void>((_, reject) => signal!.addEventListener("abort", () => {
          aborted = true; reject(signal!.reason);
        }, { once: true }));
      },
    });
    const work = yield* Effect.fork(Effect.either(installFreestyleGuestCli(fixture.client, "vm-fixture-1")));
    yield* Deferred.await(entered);
    yield* TestClock.adjust(10_000);
    const outcome = yield* Fiber.join(work);
    expect(outcome._tag).toBe("Left");
    if (outcome._tag === "Left") {
      expect(outcome.left).toMatchObject({ outcome: "guest_exit", exitCode: 124 });
      expect(outcome.left.cleanupCause).toBeInstanceOf(Error);
    }
    expect(aborted).toBe(true);
  }).pipe(Effect.provide(TestContext.TestContext)));
});

test("rollback accepts typed absence, while missing endpoints and provider outages stay unconfirmed", async () => {
  for (const [status, code] of [[404, "NOT_FOUND"], [404, "UNKNOWN"], [503, "UNAVAILABLE"]] as const) {
    const cause = new Error("bootstrap failed");
    const client = () => new Freestyle({ apiKey: "synthetic", baseUrl: "https://provider.invalid", fetch:
      (async () => Response.json({ code, message: "synthetic deletion response" }, { status })) as typeof fetch,
    });
    const result = await Effect.runPromise(Effect.either(rollbackFreestyleCreate(client, "vm-synthetic", cause)));
    if (code === "NOT_FOUND") expect(result._tag).toBe("Right");
    else {
      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.cause).toBe(cause);
        expect(result.left.cleanupCause).toBeInstanceOf(FreestyleApiError);
      }
    }
  }
});

test("a stalled VM rollback is cancelled and retains the allocated id at its deadline", async () => {
  let aborted = false;
  const cause = new Error("bootstrap failed");
  await Effect.runPromise(Effect.gen(function* () {
    const entered = yield* Deferred.make<void>();
    const client = (_?: number, signal?: AbortSignal) => new Freestyle({
      apiKey: "synthetic", baseUrl: "https://provider.invalid", fetch: (async () => {
        Effect.runSync(Deferred.succeed(entered, undefined));
        return new Promise<Response>((_, reject) => signal!.addEventListener("abort", () => {
          aborted = true; reject(signal!.reason);
        }, { once: true }));
      }) as typeof fetch,
    });
    const work = yield* Effect.fork(Effect.either(rollbackFreestyleCreate(client, "vm-synthetic", cause)));
    yield* Deferred.await(entered);
    yield* TestClock.adjust(15_000);
    const result = yield* Fiber.join(work);
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left.providerVmId).toBe("vm-synthetic");
      expect(result.left.cause).toBe(cause);
    }
    expect(aborted).toBe(true);
  }).pipe(Effect.provide(TestContext.TestContext)));
});
