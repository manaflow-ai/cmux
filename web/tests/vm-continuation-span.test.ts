import { afterAll, describe, expect, test } from "bun:test";
import { trace } from "@opentelemetry/api";
import { BasicTracerProvider, InMemorySpanExporter, SimpleSpanProcessor } from "@opentelemetry/sdk-trace-base";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as TestClock from "effect/TestClock";
import * as TestContext from "effect/TestContext";

import { createBackgroundContinuations, withVmAnswerDeadline } from "../services/vms/routeDeadline";

// Stage B's 24 h check (2026-10-14) could not count continuation outcomes:
// they were console lines only, which never reach the trace store. Each
// continuation result is now its own span, queryable by outcome.
const exporter = new InMemorySpanExporter();
const provider = new BasicTracerProvider({ spanProcessors: [new SimpleSpanProcessor(exporter)] });
trace.disable();
trace.setGlobalTracerProvider(provider);
afterAll(async () => { await provider.shutdown(); trace.disable(); });

describe("continuation result spans", () => {
  test.each([
    ["completed", Effect.sleep("2 seconds").pipe(Effect.as("paused")), "completed"],
    ["stopped", Effect.never, "stopped_at_max_duration"],
  ] as const)("a %s continuation leaves a span with its route, key and outcome", async (_label, work, outcome) => {
    exporter.reset();
    const continuations = createBackgroundContinuations();
    const background: Promise<unknown>[] = [];
    await Effect.runPromise(Effect.gen(function* () {
      const fiber = yield* Effect.fork(withVmAnswerDeadline(work as Effect.Effect<string, never>, {
        answerWithinMs: 1_000, onDeadline: () => Effect.succeed("in progress"), continueForMs: 5_000,
        label: "/api/vm/[id]/pause", continuations, continuationKey: "pause:vm-7",
        continueInBackground: (promise) => { background.push(promise); },
      }));
      yield* TestClock.adjust(1_000);
      expect(yield* Fiber.join(fiber)).toBe("in progress");
      yield* TestClock.adjust(10_000);
      yield* Effect.promise(() => Promise.all(background));
    }).pipe(Effect.provide(TestContext.TestContext)));
    await provider.forceFlush();
    const span = exporter.getFinishedSpans().find((finished) => finished.name === "cmux.vm.continuation");
    expect(span?.attributes).toMatchObject({
      "cmux.vm.continuation.route": "/api/vm/[id]/pause",
      "cmux.vm.continuation.outcome": outcome,
      "cmux.vm.continuation.key": "pause:vm-7",
    });
  });
});
