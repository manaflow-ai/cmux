import { describe, expect, test } from "bun:test";
import {
  consumeMessageBudget,
  canQueueSocketFrame,
  consumeEventBudget,
  HOST_BYTES_PER_WINDOW,
  HOST_MESSAGES_PER_WINDOW,
} from "../src/messageBudget";

describe("share socket message budget", () => {
  test("caps aggregate host bytes even when the message count is valid", () => {
    const result = consumeMessageBudget({
      startedAt: 1_000,
      count: 4,
      bytes: HOST_BYTES_PER_WINDOW - 10,
    }, "host", 11, 1_500);
    expect(result.ok).toBe(false);
  });

  test("resets byte and message counters after the window", () => {
    const result = consumeMessageBudget({
      startedAt: 1_000,
      count: HOST_MESSAGES_PER_WINDOW,
      bytes: HOST_BYTES_PER_WINDOW,
    }, "host", 128, 2_000);
    expect(result).toEqual({
      ok: true,
      window: { startedAt: 2_000, count: 1, bytes: 128 },
    });
  });

  test("bounds room events and projected socket buffering", () => {
    expect(consumeEventBudget({ startedAt: 1_000, count: 2 }, 2, 1_500).ok).toBe(false);
    expect(consumeEventBudget({ startedAt: 1_000, count: 2 }, 2, 2_000)).toEqual({
      ok: true,
      window: { startedAt: 2_000, count: 1 },
    });
    expect(canQueueSocketFrame(90, 10, 100)).toBe(false);
    expect(canQueueSocketFrame(89, 10, 100)).toBe(true);
    expect(canQueueSocketFrame(undefined, 100, 100)).toBe(false);
  });
});
