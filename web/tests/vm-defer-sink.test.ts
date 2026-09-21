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
    // The first unit parks inside its work until the test releases it. That
    // makes the ordering observable without a timer: while the first is
    // parked, a second unit that was started earlier must still be waiting.
    let releaseFirst: () => void = () => undefined;
    const firstReleased = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    let markFirstRunning: () => void = () => undefined;
    const firstRunning = new Promise<void>((resolve) => {
      markFirstRunning = resolve;
    });
    sink(async () => {
      events.push("requested:start");
      markFirstRunning();
      await firstReleased;
      events.push("requested");
    });
    sink(async () => {
      events.push("created");
    });
    expect(scheduled).toHaveLength(2);
    await Promise.resolve();
    // Nothing runs until the scheduler says so.
    expect(events).toEqual([]);

    // The scheduler starts the second unit before the first.
    const second = scheduled[1]!();
    const first = scheduled[0]!();
    await firstRunning;
    // The first is parked mid-work; the second, started earlier, waits for it.
    expect(events).toEqual(["requested:start"]);
    releaseFirst();
    await Promise.all([first, second]);
    expect(events).toEqual(["requested:start", "requested", "created"]);
  });

  test("a failed unit surfaces to the scheduler and does not block the next", async () => {
    const outcomes: string[] = [];
    const settled: Array<Promise<void>> = [];
    const sink = orderedDeferSink((work) => {
      settled.push(work().then(
        () => {
          outcomes.push("ok");
        },
        () => {
          outcomes.push("failed");
        },
      ));
    });
    const events: string[] = [];
    sink(async () => {
      throw new Error("db down");
    });
    sink(async () => {
      events.push("after");
    });
    expect(settled).toHaveLength(2);
    await Promise.all(settled);
    expect(events).toEqual(["after"]);
    expect(outcomes).toEqual(["failed", "ok"]);
  });
});
