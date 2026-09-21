import { describe, expect, test } from "bun:test";
import { orderedDeferSink } from "../services/vms/defer";

// Deferred ledger writes (vm.create.requested, then vm.created) must land in
// lifecycle order even though the platform runs after-response callbacks
// concurrently, and a unit must not start before the scheduler invokes it.
describe("orderedDeferSink", () => {
  test("runs units in hand-in order even when the scheduler starts them out of order", async () => {
    const scheduled: Array<() => Promise<void>> = [];
    const sink = orderedDeferSink((work) => {
      scheduled.push(work);
    });
    const events: string[] = [];
    sink(async () => {
      events.push("requested");
    });
    sink(async () => {
      events.push("created");
    });
    expect(scheduled).toHaveLength(2);
    await Promise.resolve();
    // Nothing runs until the scheduler says so.
    expect(events).toEqual([]);

    const second = scheduled[1]!();
    await new Promise((resolve) => setTimeout(resolve, 0));
    // The second unit waits for the first, which the scheduler has not started.
    expect(events).toEqual([]);
    const first = scheduled[0]!();
    await Promise.all([first, second]);
    expect(events).toEqual(["requested", "created"]);
  });

  test("a failed unit surfaces to the scheduler and does not block the next", async () => {
    const outcomes: string[] = [];
    const sink = orderedDeferSink((work) => {
      void work().then(() => outcomes.push("ok"), () => outcomes.push("failed"));
    });
    const events: string[] = [];
    sink(async () => {
      throw new Error("db down");
    });
    sink(async () => {
      events.push("after");
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(events).toEqual(["after"]);
    expect(outcomes).toEqual(["failed", "ok"]);
  });
});
