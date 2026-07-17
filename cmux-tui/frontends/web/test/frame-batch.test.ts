import { describe, expect, it, vi } from "vitest";
import { createFrameBatch } from "../src/lib/frameBatch";

describe("animation-frame batching", () => {
  it("coalesces multiple deltas in one frame into one latest-state publication", () => {
    const callbacks = new Map<number, FrameRequestCallback>();
    let nextFrame = 1;
    const publish = vi.fn();
    const batch = createFrameBatch(
      publish,
      (callback) => {
        const frame = nextFrame++;
        callbacks.set(frame, callback);
        return frame;
      },
      (frame) => { callbacks.delete(frame); },
    );

    batch.schedule("delta-1");
    batch.schedule("delta-2");
    batch.schedule("delta-3");
    expect(callbacks).toHaveLength(1);
    expect(publish).not.toHaveBeenCalled();

    callbacks.values().next().value?.(0);
    expect(publish).toHaveBeenCalledOnce();
    expect(publish).toHaveBeenCalledWith("delta-3");
  });

  it("cancels a pending publication during teardown", () => {
    const callbacks = new Map<number, FrameRequestCallback>();
    const publish = vi.fn();
    const batch = createFrameBatch(
      publish,
      (callback) => {
        callbacks.set(7, callback);
        return 7;
      },
      (frame) => { callbacks.delete(frame); },
    );

    batch.schedule("stale");
    batch.cancel();
    expect(callbacks).toHaveLength(0);
    expect(publish).not.toHaveBeenCalled();
  });
});
