import { describe, expect, it } from "vitest";
import { isCreateQueueFull, retryWhileQueueFull, type Answer } from "../../scripts/create-retry.ts";

const full: Answer = { status: 503, body: { message: "The cmux VM service is temporarily unavailable (vm-provider.createQueueFull)", _tag: "ServiceUnavailable" } };
const made: Answer = { status: 201, body: { id: "vm_00000000000000000000000000" } };

const clock = () => {
  let t = 0;
  return { now: () => t, sleep: async (ms: number) => { t += ms; }, log: () => {} };
};

describe("smoke create retry", () => {
  it("sends again after a full queue and returns the create that got through", async () => {
    const answers = [full, full, made];
    let sent = 0;
    const got = await retryWhileQueueFull(async () => answers[sent++]!, clock());
    expect(got).toBe(made);
    expect(sent).toBe(3);
  });

  it("returns any other answer at once", async () => {
    let sent = 0;
    const other: Answer = { status: 503, body: { message: "vm_unavailable" } };
    expect(await retryWhileQueueFull(async () => { sent++; return other; }, clock())).toBe(other);
    expect(sent).toBe(1);
  });

  it("gives up with the last full-queue answer once the budget is spent", async () => {
    let sent = 0;
    const got = await retryWhileQueueFull(async () => { sent++; return full; }, { ...clock(), budgetMs: 30_000, waitMs: 10_000 });
    expect(isCreateQueueFull(got)).toBe(true);
    expect(sent).toBe(4);
  });
});
