// Session Info's width stages, chosen by the pane's width (session-info/SessionInfo.tsx sessionInfoStage;
// Leo, 2026-11-03: "not affecting layout at all -> gradually pushing into the chat layout -> overlay"): a
// wide pane keeps it floating in the free right gutter, moving nothing (Leo, 2026-10-31: "why is the session
// info thing still pushing my layout when it doesnt need to???"); where the gutter cannot hold it and the
// pane still holds a readable chat beside it, it pushes the chat left; where pushing would leave the chat
// under a readable width (sessionInfoFits), it lies over the chat above the composer, and waits for the
// toggle before it opens. A short pane makes that overlay a popover (POPOVER_BELOW_HEIGHT).
import { expect, test } from "bun:test";
import {
  POPOVER_BELOW_HEIGHT,
  sessionInfoFits,
  sessionInfoPopover,
  sessionInfoStage,
} from "../src/agent-session/acpmux/session-info/SessionInfo";
import { SESSION_INFO_WIDTH } from "../src/agent-session/acpmux/session-info/sessionInfoState";

// The standard 720px column, pinned so the test does not read the page's width setting or scale.
const COLUMN = { min: 720, max: 720, share: 1, prose: Infinity };
const WIDTH = SESSION_INFO_WIDTH.fallback;
const TALL = 960;

const stage = (paneWidth: number, paneHeight = TALL) =>
  sessionInfoStage("overlay", { width: paneWidth, height: paneHeight }, WIDTH, COLUMN);

test("a wide pane: it floats in the free right gutter and pushes nothing", () => {
  expect(stage(1800)).toBe("float");
});

test("a middling pane: the gutter cannot hold it, so it pushes the chat left", () => {
  expect(stage(900)).toBe("push");
  expect(sessionInfoFits(900)).toBe(true);
});

test("a narrow pane: pushing would leave no readable chat, so it lies over the chat and waits for the toggle", () => {
  expect(stage(370)).toBe("overlay");
  expect(sessionInfoFits(370)).toBe(false);
});

test("the stages run gutter, then push, then overlay as the pane narrows, never back", () => {
  const order = ["overlay", "push", "float"];
  let last = 0;
  for (let width = 300; width <= 2400; width += 20) {
    const at = order.indexOf(stage(width));
    expect(at).toBeGreaterThanOrEqual(last);
    last = at;
  }
  expect(last).toBe(2);
});

test("a short pane where it would lie over the chat makes it a popover; a wide short pane keeps the gutter", () => {
  expect(stage(900, POPOVER_BELOW_HEIGHT - 1)).toBe("overlay");
  expect(sessionInfoPopover(POPOVER_BELOW_HEIGHT - 1, true)).toBe(true);
  expect(stage(1800, POPOVER_BELOW_HEIGHT - 1)).toBe("float");
});
