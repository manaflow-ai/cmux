import { describe, expect, it, vi } from "vitest";
import { createCoalescedRefresh } from "../src/lib/coalescedRefresh";

const nextTurn = () => new Promise<void>((resolve) => queueMicrotask(resolve));

describe("createCoalescedRefresh", () => {
  it("keeps one request in flight and reruns once when events arrive during it", async () => {
    let finishFirst: (() => void) | undefined;
    const operation = vi.fn()
      .mockImplementationOnce(() => new Promise<void>((resolve) => { finishFirst = resolve; }))
      .mockResolvedValue(undefined);
    const refresh = createCoalescedRefresh(operation);

    refresh();
    refresh();
    refresh();
    expect(operation).toHaveBeenCalledTimes(1);

    finishFirst?.();
    await nextTurn();
    await nextTurn();

    expect(operation).toHaveBeenCalledTimes(2);
  });

  it("allows a later retry after a failed request", async () => {
    const onError = vi.fn();
    const operation = vi.fn().mockRejectedValueOnce(new Error("closed")).mockResolvedValue(undefined);
    const refresh = createCoalescedRefresh(operation, onError);

    refresh();
    await nextTurn();
    refresh();
    await nextTurn();

    expect(operation).toHaveBeenCalledTimes(2);
    expect(onError).toHaveBeenCalledTimes(1);
  });
});
