// Session Info's width stages, chosen by the pane's width (session-info/SessionInfo.tsx): a wide pane
// keeps it floating in the free right gutter, moving nothing (Leo, 2026-10-31: "why is the session
// info thing still pushing my layout when it doesnt need to???"); where the gutter cannot hold it, it
// pushes the chat left at its own width; a pane too narrow for that pushes it at its narrow floor
// (PUSH_PANEL_MIN) and waits for the toggle before it opens (cmuxterm-hq#6137, #32591), never over the
// chat. The one stage over the chat is a short pane's popover (POPOVER_BELOW_HEIGHT).
import { expect, test } from "bun:test";
import {
  PUSH_PANEL_MIN,
  POPOVER_BELOW_HEIGHT,
  pushedWidth,
  sessionInfoFits,
  sessionInfoOverChat,
  sessionInfoPopover,
  sessionInfoPushes,
} from "../src/agent-session/acpmux/session-info/SessionInfo";
import { SESSION_INFO_WIDTH } from "../src/agent-session/acpmux/session-info/sessionInfoState";

// The standard 720px column, pinned so the test does not read the page's width setting or scale.
const COLUMN = { min: 720, max: 720, share: 1, prose: Infinity };
const WIDTH = SESSION_INFO_WIDTH.fallback;
const TALL = 960;

/// The stage SessionInfo.tsx draws for a pane, from the same decisions in the same order.
function stage(paneWidth: number, paneHeight = TALL) {
  const pane = { width: paneWidth, height: paneHeight };
  if (sessionInfoPushes("overlay", pane, WIDTH, COLUMN))
    return { stage: "push", width: pushedWidth(paneWidth, WIDTH), opensUnasked: sessionInfoFits(paneWidth) };
  const overChat = sessionInfoOverChat(paneWidth, WIDTH, COLUMN);
  if (sessionInfoPopover(paneHeight, overChat)) return { stage: "popover", width: WIDTH, opensUnasked: false };
  return { stage: overChat ? "over-chat" : "gutter", width: WIDTH, opensUnasked: true };
}

test("a wide pane: it floats in the free right gutter and pushes nothing", () => {
  expect(stage(1800)).toEqual({ stage: "gutter", width: WIDTH, opensUnasked: true });
});

test("a middling pane: the gutter cannot hold it, so it pushes the chat left at its own width", () => {
  expect(stage(900)).toEqual({ stage: "push", width: WIDTH, opensUnasked: true });
});

test("a narrow pane: it pushes at its narrow floor and waits for the toggle, never covering the chat", () => {
  expect(stage(370)).toEqual({ stage: "push", width: PUSH_PANEL_MIN, opensUnasked: false });
});

test("no tall pane of any width draws it over the chat", () => {
  for (let width = 300; width <= 2400; width += 20) expect(stage(width).stage).not.toBe("over-chat");
});

test("a short pane where it would lie over the chat makes it a popover; a wide short pane keeps the gutter", () => {
  expect(stage(900, POPOVER_BELOW_HEIGHT - 1).stage).toBe("popover");
  expect(stage(1800, POPOVER_BELOW_HEIGHT - 1).stage).toBe("gutter");
});
