// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ReconnectNotice } from "./ReconnectNotice";

describe("reconnect notice", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it("stays silent while automatic recovery is still retrying", () => {
    const { rerender } = render(<ReconnectNotice needsAction={false} onRetry={() => undefined} />);
    expect(screen.queryByRole("status")).toBeNull();
    act(() => vi.advanceTimersByTime(9_999));
    expect(screen.queryByRole("status")).toBeNull();
    rerender(<ReconnectNotice needsAction={false} onRetry={() => undefined} />);
    expect(vi.getTimerCount()).toBe(0);
    act(() => vi.advanceTimersByTime(20_000));
    expect(screen.queryByRole("status")).toBeNull();
  });

  it("shows one actionable line after a bounded failure", () => {
    const onRetry = vi.fn();
    const { rerender } = render(<ReconnectNotice needsAction onRetry={onRetry} />);
    expect(screen.queryByRole("status")).toBeNull();
    act(() => vi.advanceTimersByTime(10_000));
    expect(screen.getByRole("status").textContent).toContain("Check it, then try again");
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(onRetry).toHaveBeenCalledOnce();
    rerender(<ReconnectNotice needsAction={false} onRetry={onRetry} />);
    expect(screen.queryByRole("status")).toBeNull();
    rerender(<ReconnectNotice needsAction={true} onRetry={onRetry} />);
    act(() => vi.advanceTimersByTime(9_999));
    expect(screen.queryByRole("status")).toBeNull();
  });

  it("cancels the presentation timer when the surface unmounts", () => {
    const { unmount } = render(<ReconnectNotice needsAction onRetry={() => undefined} />);
    unmount();
    expect(vi.getTimerCount()).toBe(0);
  });
});
