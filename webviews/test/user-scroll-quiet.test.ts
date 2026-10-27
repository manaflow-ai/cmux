import { expect, jest, spyOn, test } from "bun:test";
import { USER_SCROLL_INTENT_MS, userScrollIntent } from "../src/agent-session/acpmux/conversation/userScroll";

test("quiet notification waits for the last input, stops during drag, and cleans up", () => {
  jest.useFakeTimers();
  const intent = userScrollIntent({} as HTMLElement);
  let notices = 0;
  const remove = intent.subscribeQuiet(() => notices++);
  try {
    intent.mark();
    jest.advanceTimersByTime(USER_SCROLL_INTENT_MS - 1);
    expect(notices).toBe(0);
    intent.mark();
    jest.advanceTimersByTime(USER_SCROLL_INTENT_MS - 1);
    expect(notices).toBe(0);
    jest.advanceTimersByTime(1);
    expect(notices).toBe(1);
    intent.press(true);
    intent.mark();
    jest.advanceTimersByTime(USER_SCROLL_INTENT_MS * 2);
    expect(notices).toBe(1);
    intent.press(false);
    intent.mark();
    jest.advanceTimersByTime(USER_SCROLL_INTENT_MS);
    expect(notices).toBe(2);
    intent.mark();
    remove();
    jest.advanceTimersByTime(USER_SCROLL_INTENT_MS);
    expect(notices).toBe(2);
  } finally {
    remove();
    intent.reset();
    jest.useRealTimers();
  }
});

test("an early fractional timeout rearms without notifying while input is held", () => {
  jest.useFakeTimers();
  const clock = spyOn(performance, "now").mockReturnValue(0);
  const intent = userScrollIntent({} as HTMLElement);
  let notices = 0;
  const remove = intent.subscribeQuiet(() => notices++);
  try {
    intent.mark();
    clock.mockReturnValue(999.25);
    jest.advanceTimersByTime(1000);
    expect(intent.isHeld()).toBe(true);
    expect(notices).toBe(0);
    clock.mockReturnValue(1000.25);
    jest.advanceTimersByTime(1);
    expect(intent.isHeld()).toBe(false);
    expect(notices).toBe(1);
  } finally {
    remove();
    intent.reset();
    clock.mockRestore();
    jest.useRealTimers();
  }
});
