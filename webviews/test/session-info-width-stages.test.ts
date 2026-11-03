// Session Info's width stages, chosen by the pane's width (session-info/SessionInfo.tsx sessionInfoStage,
// #32751): a wide pane keeps it floating in the free right gutter, moving nothing (Leo, 2026-10-31: "why
// is the session info thing still pushing my layout when it doesnt need to???"); where the gutter cannot
// hold it, it pushes the chat left while the pane still holds a readable chat beside it
// (sessionInfoFits); a pane too narrow for that lays it over the chat, its foot above the composer, and
// waits for the toggle before it opens (Leo, 2026-11-03: "but you should still be able to have it be an
// overlay... we previously had all that behaviour logic going from not affecting layout at all ->
// gradually pushing into the chat layout -> overlay"; #32591 for the wait). A short pane's overlay is a
// popover (POPOVER_BELOW_HEIGHT).
import { expect, test } from "bun:test";
import {
  POPOVER_BELOW_HEIGHT,
  pushedWidth,
  sessionInfoFits,
  sessionInfoOverChat,
  sessionInfoPopover,
  sessionInfoStage,
} from "../src/agent-session/acpmux/session-info/SessionInfo";
import { SESSION_INFO_WIDTH } from "../src/agent-session/acpmux/session-info/sessionInfoState";

// The standard 720px column, pinned so the test does not read the page's width setting or scale.
const COLUMN = { min: 720, max: 720, share: 1, prose: Infinity };
const WIDTH = SESSION_INFO_WIDTH.fallback;
const TALL = 960;

/// The stage SessionInfo.tsx draws for a pane, from the same decisions.
function stage(paneWidth: number, paneHeight = TALL) {
  const pane = { width: paneWidth, height: paneHeight };
  const at = sessionInfoStage("overlay", pane, WIDTH, COLUMN);
  if (at === "push") return { stage: "push", width: pushedWidth(paneWidth, WIDTH), opensUnasked: true };
  if (at === "float") return { stage: "gutter", width: WIDTH, opensUnasked: true };
  const popover = sessionInfoPopover(paneHeight, sessionInfoOverChat(paneWidth, WIDTH, COLUMN));
  return {
    stage: popover ? "popover" : "over-chat",
    width: WIDTH,
    opensUnasked: !popover && sessionInfoFits(paneWidth),
  };
}

test("a wide pane: it floats in the free right gutter and pushes nothing", () => {
  expect(stage(1800)).toEqual({ stage: "gutter", width: WIDTH, opensUnasked: true });
});

test("a middling pane: the gutter cannot hold it, so it pushes the chat left at its own width", () => {
  expect(stage(900)).toEqual({ stage: "push", width: WIDTH, opensUnasked: true });
});

test("a narrow pane: it lies over the chat above the composer and waits for the toggle", () => {
  expect(stage(370)).toEqual({ stage: "over-chat", width: WIDTH, opensUnasked: false });
});

test("a tall pane lays it over the chat only where pushing would leave too narrow a chat", () => {
  for (let width = 300; width <= 2400; width += 20)
    expect(stage(width).stage === "over-chat").toBe(!sessionInfoFits(width));
});

test("a short pane where it would lie over the chat makes it a popover; a wide short pane keeps the gutter", () => {
  expect(stage(900, POPOVER_BELOW_HEIGHT - 1).stage).toBe("popover");
  expect(stage(1800, POPOVER_BELOW_HEIGHT - 1).stage).toBe("gutter");
});
