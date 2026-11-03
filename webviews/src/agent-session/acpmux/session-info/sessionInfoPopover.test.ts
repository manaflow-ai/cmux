import { describe, expect, test } from "bun:test";
import { sessionInfoPopover, sessionInfoPushes, sessionInfoStage, POPOVER_BELOW_HEIGHT } from "./SessionInfo";

describe("sessionInfoPopover", () => {
  test("only over the chat in a short pane", () => {
    expect(sessionInfoPopover(POPOVER_BELOW_HEIGHT - 1, true)).toBe(true);
    expect(sessionInfoPopover(POPOVER_BELOW_HEIGHT, true)).toBe(false);
    expect(sessionInfoPopover(400, false)).toBe(false);
    // Unmeasured: never a popover.
    expect(sessionInfoPopover(0, true)).toBe(false);
  });

  // cmuxterm-hq#6137: a narrow, tall pane never makes it a popover. Where pushing would leave the chat
  // under 440px it lies over the chat above the composer (Leo, 2026-11-03: "but you should still be able
  // to have it be an overlay"); with room it pushes; Push always pushes wherever the column keeps its width.
  test("a narrow, tall pane lies over the chat, not as a popover", () => {
    expect(sessionInfoPopover(960, true)).toBe(false);
    expect(sessionInfoStage("overlay", { width: 370, height: 960 }, 320)).toBe("overlay");
    expect(sessionInfoStage("overlay", { width: 600, height: 960 }, 320)).toBe("overlay");
    // Pushing at 740px would narrow the column, so it lies over the chat (Leo, 2026-11-03: "if it would
    // need to be then session info should be an overlay"); at 1100px the push keeps the column's width.
    expect(sessionInfoStage("overlay", { width: 740, height: 960 }, 320)).toBe("overlay");
    expect(sessionInfoStage("overlay", { width: 1100, height: 960 }, 320)).toBe("push");
    expect(sessionInfoPushes("push", { width: 370, height: 960 }, 320)).toBe(false);
    expect(sessionInfoPushes("push", { width: 1800, height: 960 }, 320)).toBe(true);
  });
});
