import { describe, expect, test } from "bun:test";
import type { Span } from "@opentelemetry/api";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";

import { measureVmEffect, VmTimingRecorder, type VmTimingStage } from "../services/vms/timings";

describe("VM timing helpers", () => {
  test("records Effect timings when the fiber is interrupted", async () => {
    const recorded: Array<{ stage: VmTimingStage; durationMs: number }> = [];
    const timing = {
      record: (stage: VmTimingStage, durationMs: number) => {
        recorded.push({ stage, durationMs });
      },
    };

    const fiber = Effect.runFork(
      measureVmEffect(timing, "provider_create", Effect.never),
    );

    await Effect.runPromise(Fiber.interrupt(fiber));

    expect(recorded).toHaveLength(1);
    expect(recorded[0]?.stage).toBe("provider_create");
    expect(recorded[0]?.durationMs).toBeGreaterThanOrEqual(0);
  });

  test("Server-Timing lists every recorded stage in milliseconds", () => {
    const attributes: Array<{ key: string; value: unknown }> = [];
    const span = { setAttribute: (key: string, value: unknown) => attributes.push({ key, value }) } as unknown as Span;
    const recorder = new VmTimingRecorder(span, "create", { debugTimings: false });
    recorder.record("auth", 12.345);
    recorder.record("provider_create", 250);
    recorder.record("provider_create", 50);
    expect(recorder.serverTimingHeader()).toBe("auth;dur=12.35, provider_create;dur=300");
  });

  test("finish is idempotent", () => {
    const attributes: Array<{ key: string; value: unknown }> = [];
    const span = {
      setAttribute: (key: string, value: unknown) => {
        attributes.push({ key, value });
      },
    } as unknown as Span;
    const recorder = new VmTimingRecorder(span, "create", {
      startedAt: performance.now(),
    });

    recorder.finish({ status: 200 });
    recorder.finish({ status: 200 });

    expect(attributes.filter((attribute) => attribute.key === "cmux.vm.timing.total_ms")).toHaveLength(1);
    expect(attributes.filter((attribute) => attribute.key === "cmux.vm.timing.total_count")).toHaveLength(1);
  });
});
