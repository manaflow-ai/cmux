// Session Info's width stages, chosen by the pane's width (session-info/SessionInfo.tsx sessionInfoStage):
// a wide pane keeps it floating in the free right gutter, moving nothing (Leo, 2026-10-31: "why is the
// session info thing still pushing my layout when it doesnt need to???"); where the gutter cannot hold
// it, it pushes the chat left, but only while the transcript's column keeps its width (Leo, 2026-11-03:
// "the agent chat's horizontal width shouldn't be shifted its position sure but it itself and its text
// shouldn't be affected by the session info if it would need to be then session info should be an
// overlay"); everywhere else it lies over the chat above the composer, and in a short pane it is a
// popover (POPOVER_BELOW_HEIGHT). A narrow pane waits for the toggle before it opens (cmuxterm-hq#6137).
import { expect, test } from "bun:test";
import {
  POPOVER_BELOW_HEIGHT,
  pushedRoom,
  pushedWidth,
  pushKeepsColumn,
  sessionInfoFits,
  sessionInfoPopover,
  sessionInfoStage,
  type SessionInfoPlacement,
} from "../src/agent-session/acpmux/session-info/SessionInfo";
import { SESSION_INFO_WIDTH } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { transcriptColumn } from "../src/agent-session/acpmux/model";
import type { ChatColumn } from "../src/agent-session/acpmux/chatWidth";

// The standard column (chatWidth.ts COLUMNS.standard: 720px, 62.5% of a wider pane up to 800px), pinned
// so the test does not read the page's width setting or scale.
const STANDARD: ChatColumn = { min: 720, max: 800, share: 0.625, prose: Infinity };
const WIDE: ChatColumn = { min: 720, max: 960, share: 0.625, prose: Infinity };
const WIDTH = SESSION_INFO_WIDTH.fallback;
const TALL = 960;

/// The stage SessionInfo.tsx draws for a pane, and the room a push takes from the chat.
function stage(paneWidth: number, paneHeight = TALL, placement: SessionInfoPlacement = "overlay", column = STANDARD) {
  const pane = { width: paneWidth, height: paneHeight };
  const at = sessionInfoStage(placement, pane, WIDTH, column);
  const panel = at === "push" ? pushedWidth(paneWidth, WIDTH) : WIDTH;
  const room = at === "push" ? pushedRoom(paneWidth, panel, column, 0, placement === "push") : 0;
  const popover = at === "overlay" && sessionInfoPopover(paneHeight, true);
  return { stage: popover ? "popover" : at, room, opensUnasked: !popover && sessionInfoFits(paneWidth) };
}

test("a wide pane: it floats in the free right gutter and pushes nothing", () => {
  expect(stage(1800)).toEqual({ stage: "float", room: 0, opensUnasked: true });
});

test("where the gutter lacks a little, it pushes the column left at its own width", () => {
  const { stage: at, room } = stage(1420);
  expect(at).toBe("push");
  expect(room).toBeGreaterThan(0);
  expect(transcriptColumn(1420 - room, STANDARD).width).toBe(transcriptColumn(1420, STANDARD).width);
});

test("where pushing would narrow the column (its 62.5% share), it lies over the chat instead", () => {
  expect(stage(1240).stage).toBe("overlay");
  expect(stage(900).stage).toBe("overlay");
});

test("a narrow pane: over the chat, waiting for the toggle before it opens", () => {
  expect(stage(370)).toEqual({ stage: "overlay", room: 0, opensUnasked: false });
});

// Leo's rule, over every pane width and both placements: a push never changes the column's width, so no
// line of the chat wraps anew when Session Info opens or closes.
for (const placement of ["overlay", "push"] as const)
  for (const [name, column] of [
    ["standard", STANDARD],
    ["wide", WIDE],
  ] as const)
    test(`${placement}, ${name} column: no pane width from 600 to 2400 pushes the column narrower`, () => {
      let pushed = 0;
      for (let paneWidth = 600; paneWidth <= 2400; paneWidth += 20) {
        const at = sessionInfoStage(placement, { width: paneWidth, height: TALL }, WIDTH, column);
        if (at !== "push") continue;
        pushed++;
        const room = pushedRoom(paneWidth, pushedWidth(paneWidth, WIDTH), column, 0, placement === "push");
        expect(room % 2).toBe(0);
        expect(pushKeepsColumn(paneWidth, room, column)).toBe(true);
        expect(transcriptColumn(paneWidth - room, column).width).toBe(transcriptColumn(paneWidth, column).width);
      }
      // Pushing still happens somewhere: the rule narrows push, it does not remove it.
      expect(pushed).toBeGreaterThan(0);
    });

test("every pixel width from 600 to 2400: a push keeps the column's width on its end frame", () => {
  for (let paneWidth = 600; paneWidth <= 2400; paneWidth++) {
    if (sessionInfoStage("overlay", { width: paneWidth, height: TALL }, WIDTH, STANDARD) !== "push") continue;
    const room = pushedRoom(paneWidth, pushedWidth(paneWidth, WIDTH), STANDARD);
    expect(transcriptColumn(paneWidth - room, STANDARD).width).toBe(transcriptColumn(paneWidth, STANDARD).width);
  }
});

test("Settings Push always pushes wherever its whole room keeps the column, else lies over the chat", () => {
  expect(stage(2000, TALL, "push").stage).toBe("push");
  expect(stage(2000, TALL, "push").room).toBe(WIDTH + 8);
  expect(stage(1300, TALL, "push").stage).toBe("overlay");
});

test("Push always stays flush and keeps its pinned column across adjacent pane and panel widths", () => {
  for (let paneWidth = 1792; paneWidth <= 1816; paneWidth++) {
    for (let panel = 296; panel <= 312; panel++) {
      const pane = { width: paneWidth, height: TALL };
      expect(sessionInfoStage("push", pane, panel, STANDARD)).toBe("push");
      const room = pushedRoom(paneWidth, panel, STANDARD, 0, true);
      expect(room).toBe(panel + 8);
      expect(pushKeepsColumn(paneWidth, room, STANDARD, true)).toBe(true);
      // This is the width CSS can draw while keeping the minimum page edge on either side.
      expect(paneWidth - room - 2 * transcriptColumn(0, STANDARD).inset).toBeGreaterThanOrEqual(
        transcriptColumn(paneWidth, STANDARD).width,
      );
    }
  }
});

test("a short pane where it would lie over the chat makes it a popover; a wide short pane keeps the gutter", () => {
  expect(stage(900, POPOVER_BELOW_HEIGHT - 1).stage).toBe("popover");
  expect(stage(1800, POPOVER_BELOW_HEIGHT - 1).stage).toBe("float");
});
