// The open hat's list goes toward free space (subagents/hatOpens.ts; Leo, 2026-11-27, CMUX-863).
import { describe, expect, test } from "bun:test";
import { hatOpens } from "../src/agent-session/acpmux/subagents/hatOpens";

describe("the open hat goes toward free space", () => {
  test("room below: it opens under its header, as it always has", () => {
    expect(hatOpens({ above: 400, below: 300, list: 140 })).toBe("down");
  });
  test("no room below: it opens upward", () => {
    expect(hatOpens({ above: 400, below: 12, list: 140 })).toBe("up");
  });
  test("tight both ways: the larger side, where the list scrolls", () => {
    expect(hatOpens({ above: 90, below: 60, list: 140 })).toBe("up");
    expect(hatOpens({ above: 60, below: 90, list: 140 })).toBe("down");
  });
  test("an even split stays under the header", () => {
    expect(hatOpens({ above: 60, below: 60, list: 140 })).toBe("down");
  });
});
