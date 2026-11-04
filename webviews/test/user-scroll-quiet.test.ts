import { expect, jest, spyOn, test } from "bun:test";
import {
  USER_SCROLL_INTENT_MS,
  attachUserScrollIntent,
  userScrollIntent,
} from "../src/agent-session/acpmux/conversation/userScroll";

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

// A drag can end without a pointerup: the next pointermove reports no buttons, or the window loses
// focus. Either way the release starts the quiet interval, as a pointerup does.
for (const ending of ["pointermove without buttons", "window blur"] as const) {
  test(`a drag ended by ${ending} still holds for the quiet interval`, () => {
    jest.useFakeTimers();
    const clock = spyOn(performance, "now").mockReturnValue(0);
    const listeners = new Map<string, (event: Event) => void>();
    const target = {
      addEventListener: (name: string, listener: (event: Event) => void) => listeners.set(name, listener),
      removeEventListener: () => {},
      contains: () => true,
    };
    const page = { ...target, defaultView: target, body: {} };
    const node = { ...target, ownerDocument: page } as unknown as HTMLElement;
    const detach = attachUserScrollIntent(node);
    const intent = userScrollIntent(node);
    let notices = 0;
    const remove = intent.subscribeQuiet(() => notices++);
    try {
      listeners.get("pointerdown")!({ type: "pointerdown" } as Event);
      clock.mockReturnValue(2000);
      jest.advanceTimersByTime(2000);
      expect(intent.isHeld()).toBe(true);
      if (ending === "window blur") listeners.get("blur")!({ type: "blur" } as Event);
      else listeners.get("pointermove")!({ type: "pointermove", buttons: 0 } as unknown as Event);
      expect(intent.isHeld()).toBe(true);
      clock.mockReturnValue(2000 + USER_SCROLL_INTENT_MS - 1);
      jest.advanceTimersByTime(USER_SCROLL_INTENT_MS - 1);
      expect(intent.isHeld()).toBe(true);
      expect(notices).toBe(0);
      clock.mockReturnValue(2000 + USER_SCROLL_INTENT_MS);
      jest.advanceTimersByTime(1);
      expect(intent.isHeld()).toBe(false);
      expect(notices).toBe(1);
    } finally {
      remove();
      detach();
      clock.mockRestore();
      jest.useRealTimers();
    }
  });
}
