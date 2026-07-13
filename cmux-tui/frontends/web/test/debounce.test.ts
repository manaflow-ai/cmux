import { afterEach, describe, expect, it, vi } from "vitest";
import { debounce } from "../src/lib/debounce";

describe("debounce", () => {
  afterEach(() => vi.useRealTimers());

  it("runs once with the final arguments after the trailing delay", () => {
    vi.useFakeTimers();
    const callback = vi.fn();
    const debounced = debounce(callback, 100);
    debounced("first");
    vi.advanceTimersByTime(50);
    debounced("final");
    vi.advanceTimersByTime(99);
    expect(callback).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(callback).toHaveBeenCalledOnce();
    expect(callback).toHaveBeenCalledWith("final");
  });

  it("cancels pending work", () => {
    vi.useFakeTimers();
    const callback = vi.fn();
    const debounced = debounce(callback, 100);
    debounced();
    debounced.cancel();
    vi.runAllTimers();
    expect(callback).not.toHaveBeenCalled();
  });
});
