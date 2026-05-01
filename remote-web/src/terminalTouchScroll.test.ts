import { expect, test } from "bun:test";
import {
  beginTerminalTouchScroll,
  createTerminalTouchScrollState,
  endTerminalTouchScroll,
  scrollTerminalViewportByTouch,
} from "./terminalTouchScroll";

test("scrolls viewport by touch movement delta", () => {
  const state = createTerminalTouchScrollState();
  const viewport = { scrollTop: 100 };

  beginTerminalTouchScroll(state, 300);
  expect(scrollTerminalViewportByTouch(state, 250, viewport)).toBe(50);
  expect(viewport.scrollTop).toBe(150);
  expect(scrollTerminalViewportByTouch(state, 275, viewport)).toBe(-25);
  expect(viewport.scrollTop).toBe(125);
});

test("resets touch scroll state on end", () => {
  const state = createTerminalTouchScrollState();
  const viewport = { scrollTop: 20 };

  beginTerminalTouchScroll(state, 200);
  endTerminalTouchScroll(state);
  expect(scrollTerminalViewportByTouch(state, 100, viewport)).toBe(0);
  expect(viewport.scrollTop).toBe(20);
});
