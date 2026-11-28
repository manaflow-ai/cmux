import { describe, expect, test } from "bun:test";
import {
  CAPACITY_HOLD_ENV,
  CapacityHold,
  DEFAULT_CAPACITY_HOLD_MS,
  capacityHoldBudgetMs,
  sleepWithSignal,
} from "../services/coderouter/capacityHold";

function logicalHold(budgetMs: number, headerDeadlineAt: number, random = () => 0) {
  let clock = 0;
  const sleeps: number[] = [];
  const hold = new CapacityHold({
    now: () => clock,
    sleep: async (ms) => {
      sleeps.push(ms);
      clock += ms;
    },
    random,
  }, 0, budgetMs, headerDeadlineAt);
  return { hold, sleeps, clock: () => clock };
}

describe("capacity hold", () => {
  test("backs off exponentially with jitter up to a thirty-second cap", async () => {
    const { hold, sleeps } = logicalHold(20 * 60_000, 25 * 60_000);
    const signal = new AbortController().signal;
    for (let round = 0; round < 8; round += 1) expect(await hold.wait(undefined, signal)).toBe(true);
    expect(sleeps).toEqual([500, 1_000, 2_000, 4_000, 8_000, 15_000, 15_000, 15_000]);
    expect(hold.holdCount).toBe(8);
    expect(hold.heldMs).toBe(sleeps.reduce((total, ms) => total + ms, 0));
  });

  test("honors a cooldown longer than the backoff, plus jitter", async () => {
    const { hold, sleeps } = logicalHold(20 * 60_000, 25 * 60_000, () => 0.5);
    expect(await hold.wait(42_000, new AbortController().signal)).toBe(true);
    expect(sleeps).toEqual([42_500]);
  });

  test("refuses to hold past the budget or without a recovery in sight", async () => {
    const { hold, sleeps } = logicalHold(60_000, 25 * 60_000);
    const signal = new AbortController().signal;
    expect(await hold.wait(null, signal)).toBe(false);
    expect(await hold.wait(61_000, signal)).toBe(false);
    expect(sleeps).toEqual([]);
  });

  test("leaves header time for the attempt that follows the hold", async () => {
    const { hold } = logicalHold(20 * 60_000, 30_000);
    const signal = new AbortController().signal;
    expect(await hold.wait(19_000, signal)).toBe(true);
    expect(await hold.wait(1_500, signal)).toBe(false);
  });

  test("reads the budget from the environment within bounds", () => {
    expect(capacityHoldBudgetMs({})).toBe(DEFAULT_CAPACITY_HOLD_MS);
    expect(capacityHoldBudgetMs({ [CAPACITY_HOLD_ENV]: "0" })).toBe(0);
    expect(capacityHoldBudgetMs({ [CAPACITY_HOLD_ENV]: "90000" })).toBe(90_000);
    expect(capacityHoldBudgetMs({ [CAPACITY_HOLD_ENV]: "999999999" })).toBe(25 * 60_000);
    expect(capacityHoldBudgetMs({ [CAPACITY_HOLD_ENV]: "soon" })).toBe(DEFAULT_CAPACITY_HOLD_MS);
  });

  test("a cancelled request stops waiting", async () => {
    const controller = new AbortController();
    const pending = sleepWithSignal(60_000, controller.signal);
    controller.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
  });
});
