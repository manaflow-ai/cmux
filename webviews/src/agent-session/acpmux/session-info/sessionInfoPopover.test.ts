import { describe, expect, test } from "bun:test";
import { transcriptColumn } from "../model";
import { SESSION_INFO_WIDTH } from "./sessionInfoState";
import {
  FLOAT_MARGIN,
  POPOVER_BELOW_HEIGHT,
  pushedRoom,
  pushedWidth,
  sessionInfoPopover,
  sessionInfoPushes,
  sessionInfoStage,
} from "./SessionInfo";

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

  // Dragging the panel's left edge to resize it pushes the chat left instead of lying over it (Leo,
  // 2026-11-02: "THIS IS NOT F***ING HARD TO UNDERSTAND"). The drag sets the width on every move
  // (setSessionInfoWidth), so each width it passes through must keep the transcript's column clear
  // of the panel: in a pane that can push, a wider panel never turns into an overlay, the chat gives
  // up more room as the panel grows, and the column always ends left of the panel.
  test("dragging the edge wider pushes the chat left and never covers it", () => {
    for (const paneWidth of [760, 900, 1000, 1200, 1600]) {
      const pane = { width: paneWidth, height: 960 };
      let lastRoom = 0;
      let lastLeft = Number.POSITIVE_INFINITY;
      for (let width = SESSION_INFO_WIDTH.min; width <= SESSION_INFO_WIDTH.max; width += 4) {
        const stage = sessionInfoStage("overlay", pane, width);
        expect(stage).not.toBe("overlay");
        if (stage !== "push") continue;
        const panel = pushedWidth(paneWidth, width);
        const room = pushedRoom(paneWidth, panel);
        const chat = paneWidth - room;
        const columnEnd = chat - transcriptColumn(chat).inset;
        const panelLeft = paneWidth - panel - FLOAT_MARGIN;
        expect(columnEnd).toBeLessThanOrEqual(panelLeft);
        expect(room).toBeGreaterThanOrEqual(lastRoom);
        expect(panelLeft).toBeLessThanOrEqual(lastLeft);
        lastRoom = room;
        lastLeft = panelLeft;
      }
    }
    // Where the gutter cannot hold the widest panel, the drag really moves the chat.
    expect(sessionInfoStage("overlay", { width: 900, height: 960 }, SESSION_INFO_WIDTH.max)).toBe("push");
    const widest = pushedWidth(900, SESSION_INFO_WIDTH.max);
    expect(pushedRoom(900, widest)).toBeGreaterThan(pushedRoom(900, pushedWidth(900, SESSION_INFO_WIDTH.min)));
  });
});
