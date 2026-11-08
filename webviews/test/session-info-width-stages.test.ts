// Session Info's width stages, chosen by the pane's width (session-info/SessionInfo.tsx sessionInfoStage):
// wherever the column fits beside the whole panel, a wide pane too, it pushes the chat left by the whole
// panel, so the chat is centered beside it (Lucas, 2026-11-06: "we need to make sure that the chat is
// centered when the session info is open"; it floated in a wide gutter before, Leo, 2026-10-31); a short
// wide pane still floats it in the gutter. It pushes only while the transcript's column keeps its width (Leo, 2026-11-03:
// "the agent chat's horizontal width shouldn't be shifted its position sure but it itself and its text
// shouldn't be affected by the session info if it would need to be then session info should be an
// overlay"). Pushed, the page pins the column to its whole-pane width (sessionInfo.css), so it pushes
// wherever that pinned column fits in the chat beside the panel (Lucas, 2026-11-06: the chat shifts
// left as Codex's does, and the panel never covers the prompts); everywhere else it lies over the chat
// above the composer, and in a short pane it is a popover (POPOVER_BELOW_HEIGHT). A narrow pane waits
// for the toggle before it opens (cmuxterm-hq#6137).
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
} from "../src/agent-session/acpmux/session-info/sessionInfoModel";
import { SESSION_INFO_WIDTH } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { transcriptColumn } from "../src/agent-session/acpmux/model";
import type { ChatColumn } from "../src/agent-session/acpmux/chatWidth";

// Chat Text Width's default column (chatWidth.ts displayColumn: the pane's width up to 800px, at least
// 720px) and a 960px one, pinned so the test does not read the page's width setting or scale.
const STANDARD: ChatColumn = { min: 720, max: 800 };
const WIDE: ChatColumn = { min: 720, max: 960 };
const WIDTH = SESSION_INFO_WIDTH.fallback;
const TALL = 960;

/// Pushed, the column keeps its whole-pane width, centered unrounded in the chat, never nearer its sides
/// than the page edge (sessionInfo.css --acpmux-session-info-column): where it fits, and where it ends.
const pinnedFits = (paneWidth: number, room: number, column = STANDARD) =>
  paneWidth - room >= transcriptColumn(paneWidth, column).width + 2 * transcriptColumn(0, column).inset;
const pinnedEnd = (paneWidth: number, room: number, column = STANDARD) => {
  const chat = paneWidth - room;
  return chat - Math.max(transcriptColumn(0, column).inset, (chat - transcriptColumn(paneWidth, column).width) / 2);
};

/// The stage SessionInfo.tsx draws for a pane, and the room a push takes from the chat.
function stage(paneWidth: number, paneHeight = TALL, placement: SessionInfoPlacement = "overlay", column = STANDARD) {
  const pane = { width: paneWidth, height: paneHeight };
  const at = sessionInfoStage(placement, pane, WIDTH, column);
  const panel = at === "push" ? pushedWidth(paneWidth, WIDTH) : WIDTH;
  const room = at === "push" ? pushedRoom(paneWidth, panel, column, 0, placement === "push") : 0;
  const popover = at === "overlay" && sessionInfoPopover(paneHeight, true);
  return { stage: popover ? "popover" : at, room, opensUnasked: !popover && sessionInfoFits(paneWidth) };
}

test("a wide pane: it pushes the chat by the whole panel, centered beside it", () => {
  const panel = pushedWidth(1800, WIDTH);
  expect(stage(1800)).toEqual({ stage: "push", room: panel + 8, opensUnasked: true });
  // The column's gap on the left is its gap to the panel's margin on the right.
  const chat = 1800 - (panel + 8);
  const left = (chat - transcriptColumn(1800, STANDARD).width) / 2;
  expect(chat - pinnedEnd(1800, panel + 8)).toBeCloseTo(left, 5);
  // A short wide pane keeps it floating in the free right gutter (its popover rule), moving nothing.
  expect(stage(1800, POPOVER_BELOW_HEIGHT - 1).stage).toBe("float");
});

test("where the gutter lacks a little, it pushes the column left at its own width", () => {
  const { stage: at, room } = stage(1420);
  expect(at).toBe("push");
  expect(room).toBeGreaterThan(0);
  expect(pinnedFits(1420, room)).toBe(true);
  expect(pinnedEnd(1420, room)).toBeLessThanOrEqual(1420 - pushedWidth(1420, WIDTH) - 16);
});

test("where the column's share scales with the pane, it still pushes the pinned column left", () => {
  // At 1240px the column is Chat Text Width's 800px; pushed, it keeps that width, pinned.
  const { stage: at, room } = stage(1240);
  expect(at).toBe("push");
  expect(pinnedFits(1240, room)).toBe(true);
  expect(pinnedEnd(1240, room)).toBeLessThanOrEqual(1240 - pushedWidth(1240, WIDTH) - 16);
});

test("where the pinned column cannot fit beside the panel, it lies over the chat instead", () => {
  expect(stage(1100).stage).toBe("overlay");
  expect(stage(900).stage).toBe("overlay");
});

test("a narrow pane: over the chat, waiting for the toggle before it opens", () => {
  expect(stage(370)).toEqual({ stage: "overlay", room: 0, opensUnasked: false });
});

// Leo's rule, over every pane width and both placements: a push never changes the column's width (the
// pinned column fits in the chat), so no line of the chat wraps anew when Session Info opens or closes,
// and the column ends left of the panel.
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
        expect(pinnedFits(paneWidth, room, column)).toBe(true);
        expect(pinnedEnd(paneWidth, room, column)).toBeLessThanOrEqual(paneWidth - pushedWidth(paneWidth, WIDTH) - 16);
      }
      // Pushing still happens somewhere: the rule narrows push, it does not remove it.
      expect(pushed).toBeGreaterThan(0);
    });

test("every pixel width from 600 to 2400: a push keeps the pinned column clear of the panel on its end frame", () => {
  for (let paneWidth = 600; paneWidth <= 2400; paneWidth++) {
    if (sessionInfoStage("overlay", { width: paneWidth, height: TALL }, WIDTH, STANDARD) !== "push") continue;
    const panel = pushedWidth(paneWidth, WIDTH);
    const room = pushedRoom(paneWidth, panel, STANDARD);
    expect(pinnedFits(paneWidth, room)).toBe(true);
    expect(pinnedEnd(paneWidth, room)).toBeLessThanOrEqual(paneWidth - panel - 16);
  }
});

test("Settings Push always pushes wherever its whole room keeps the pinned column, else lies over the chat", () => {
  expect(stage(2000, TALL, "push").stage).toBe("push");
  expect(stage(2000, TALL, "push").room).toBe(WIDTH + 8);
  expect(stage(1300, TALL, "push").stage).toBe("push");
  expect(pinnedFits(1300, stage(1300, TALL, "push").room)).toBe(true);
  expect(stage(1100, TALL, "push").stage).toBe("overlay");
});

test("Push always stays flush and keeps its pinned column across adjacent pane and panel widths", () => {
  for (let paneWidth = 1792; paneWidth <= 1816; paneWidth++) {
    for (let panel = 296; panel <= 312; panel++) {
      const pane = { width: paneWidth, height: TALL };
      expect(sessionInfoStage("push", pane, panel, STANDARD)).toBe("push");
      const room = pushedRoom(paneWidth, panel, STANDARD, 0, true);
      expect(room).toBe(panel + 8);
      expect(pushKeepsColumn(paneWidth, room, STANDARD)).toBe(true);
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
