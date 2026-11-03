import { describe, expect, test } from "bun:test";
import { sessionInfoPopover, sessionInfoPushes, POPOVER_BELOW_HEIGHT } from "./SessionInfo";

describe("sessionInfoPopover", () => {
  test("only over the chat in a short pane", () => {
    expect(sessionInfoPopover(POPOVER_BELOW_HEIGHT - 1, true)).toBe(true);
    expect(sessionInfoPopover(POPOVER_BELOW_HEIGHT, true)).toBe(false);
    expect(sessionInfoPopover(400, false)).toBe(false);
    // Unmeasured: never a popover.
    expect(sessionInfoPopover(0, true)).toBe(false);
  });

  // cmuxterm-hq#6137: a narrow pane never makes it a popover: it pushes, at a narrower floor.
  test("a narrow, tall pane pushes instead", () => {
    expect(sessionInfoPopover(960, true)).toBe(false);
    expect(sessionInfoPushes("overlay", { width: 370, height: 960 }, 320)).toBe(true);
    expect(sessionInfoPushes("overlay", { width: 600, height: 960 }, 320)).toBe(true);
    expect(sessionInfoPushes("push", { width: 370, height: 960 }, 320)).toBe(true);
  });
});
