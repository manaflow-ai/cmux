import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";

import { measureVmEffect, type VmTimingStage } from "../services/vms/timings";

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
});
