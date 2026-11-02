import { describe, expect, test } from "bun:test";
import { sessionInfoPopover, sessionInfoPushes, tooNarrowToPush, POPOVER_BELOW_HEIGHT } from "./SessionInfo";

describe("sessionInfoPopover", () => {
  test("only over the chat in a short pane", () => {
    expect(sessionInfoPopover(POPOVER_BELOW_HEIGHT - 1, true)).toBe(true);
    expect(sessionInfoPopover(POPOVER_BELOW_HEIGHT, true)).toBe(false);
    expect(sessionInfoPopover(400, false)).toBe(false);
    // Unmeasured: never a popover.
    expect(sessionInfoPopover(0, true)).toBe(false);
  });

  // cmuxterm-hq#6137: a 370px pane pushed the chat to about 100px. Under 528px (the chat would be
  // narrower than the 260px panel beside it) the panel is a popover over the chat instead.
  test("in a pane too narrow to keep the chat as wide as the panel", () => {
    expect(tooNarrowToPush(370)).toBe(true);
    expect(tooNarrowToPush(527)).toBe(true);
    expect(tooNarrowToPush(528)).toBe(false);
    expect(tooNarrowToPush(0)).toBe(false);
    expect(sessionInfoPopover(960, true, 370)).toBe(true);
    expect(sessionInfoPopover(960, false, 370)).toBe(false);
    expect(sessionInfoPushes("overlay", { width: 370, height: 960 }, 320)).toBe(false);
    // A diff split that halves a wider pane still pushes.
    expect(sessionInfoPushes("overlay", { width: 600, height: 960 }, 320)).toBe(true);
    // Settings Push always keeps its column.
    expect(sessionInfoPushes("push", { width: 370, height: 960 }, 320)).toBe(true);
  });
});
