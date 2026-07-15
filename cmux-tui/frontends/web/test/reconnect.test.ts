import { describe, expect, it } from "vitest";
import { reconnectTransition } from "../src/lib/reconnect";

describe("reconnectTransition", () => {
  it("advances through exponential retry states and caps the delay", () => {
    expect(reconnectTransition({ attempt: 0, delayMs: 0 }, "retry")).toEqual({ attempt: 1, delayMs: 500 });
    expect(reconnectTransition({ attempt: 3, delayMs: 2_000 }, "retry")).toEqual({ attempt: 4, delayMs: 4_000 });
    expect(reconnectTransition({ attempt: 8, delayMs: 8_000 }, "retry")).toEqual({ attempt: 9, delayMs: 8_000 });
  });

  it("returns to the connected baseline after a successful attempt", () => {
    expect(reconnectTransition({ attempt: 4, delayMs: 4_000 }, "connected")).toEqual({ attempt: 0, delayMs: 0 });
  });
});
