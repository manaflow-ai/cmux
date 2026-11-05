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

  // Dragging the panel's left edge resizes it (setSessionInfoWidth on every move), and the chat
  // makes room by moving left instead of lying under it (Leo, 2026-11-02: "THIS IS NOT F***ING HARD TO
  // UNDERSTAND"), never narrowing the transcript's column (Leo, 2026-11-03: "if it would need to be
  // then session info should be an overlay", #33037). So each width a drag passes through only moves
  // the stage on from float to push to overlay, and while it pushes, the room grows with the panel,
  // the column keeps its width and ends left of the panel.
  test("dragging the edge wider pushes the chat left until the column would narrow", () => {
    const order = ["float", "push", "overlay"];
    for (const paneWidth of [760, 900, 1100, 1200, 1400, 1600, 2000]) {
      const pane = { width: paneWidth, height: 960 };
      let lastStage = 0;
      let lastRoom = 0;
      for (let width = SESSION_INFO_WIDTH.min; width <= SESSION_INFO_WIDTH.max; width += 2) {
        const stage = order.indexOf(sessionInfoStage("overlay", pane, width));
        expect(stage).toBeGreaterThanOrEqual(lastStage);
        lastStage = stage;
        if (order[stage] !== "push") continue;
        const panel = pushedWidth(paneWidth, width);
        const room = pushedRoom(paneWidth, panel);
        const chat = paneWidth - room;
        expect(room).toBeGreaterThanOrEqual(lastRoom);
        expect(transcriptColumn(chat).width).toBe(transcriptColumn(paneWidth).width);
        expect(chat - transcriptColumn(chat).inset).toBeLessThanOrEqual(paneWidth - panel - FLOAT_MARGIN);
        lastRoom = room;
      }
    }
    // Where the gutter stops holding the panel, the drag really moves the chat.
    const pane = { width: 1400, height: 960 };
    const pushing = Array.from({ length: 151 }, (_, i) => SESSION_INFO_WIDTH.min + 2 * i).filter(
      (width) => sessionInfoStage("overlay", pane, width) === "push",
    );
    expect(pushing.length).toBeGreaterThan(1);
    const roomAt = (width: number) => pushedRoom(1400, pushedWidth(1400, width));
    expect(roomAt(pushing[pushing.length - 1])).toBeGreaterThan(roomAt(pushing[0]));
  });

  // The stage at each pane width the browser suites open (thread-minimap-left-rail-stays,
  // session-info-overlay-toggle), at the panel's default width in a tall pane: by default it floats in
  // the gutter at 1600px, pushes where that keeps the column's width (1084px and 1100px) and lies over
  // the chat elsewhere (#33037). Push always takes its whole room, so it lies over the chat at 1600px
  // too, where that room would narrow the column.
  test("pins the stage at each width the browser suites open", () => {
    const widths = [1600, 1200, 1100, 1084, 800, 780, 760];
    const stages = (placement: "overlay" | "push") =>
      widths.map((width) => sessionInfoStage(placement, { width, height: 900 }, SESSION_INFO_WIDTH.fallback));
    expect(stages("overlay")).toEqual(["float", "overlay", "push", "push", "overlay", "overlay", "overlay"]);
    expect(stages("push")).toEqual(["overlay", "overlay", "push", "push", "overlay", "overlay", "overlay"]);
  });
});
