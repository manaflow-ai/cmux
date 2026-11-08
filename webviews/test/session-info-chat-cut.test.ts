// Session Info's box is cut out of the transcript where they overlap (session-info/chatCut.ts), so
// nothing scrolls behind it (Leo, 2026-11-03: "the session info thing not flicker EVER when im
// scrolling"); where they do not overlap, the transcript keeps its whole box.
import { expect, test } from "bun:test";
import { chatCut } from "../src/agent-session/acpmux/session-info/chatCut";

const scroller = { left: 100, top: 44, right: 900, bottom: 744 };

test("the panel over the chat's right side is a hole in the scroller's own px", () => {
  expect(chatCut(scroller, { left: 560, top: 56, right: 888, bottom: 400.25 })).toBe(
    "polygon(evenodd, 0 0, 100% 0, 100% 100%, 0 100%, 0 0, 460px 12px, 460px 356.5px, 788px 356.5px, 788px 12px, 460px 12px)",
  );
});

test("a panel reaching past the scroller is cut only where it overlaps", () => {
  expect(chatCut(scroller, { left: 700, top: 0, right: 1000, bottom: 300 })).toBe(
    "polygon(evenodd, 0 0, 100% 0, 100% 100%, 0 100%, 0 0, 600px 0px, 600px 256px, 800px 256px, 800px 0px, 600px 0px)",
  );
});

test("a panel beside the transcript cuts nothing", () => {
  expect(chatCut(scroller, { left: 900, top: 56, right: 1200, bottom: 400 })).toBeUndefined();
  expect(chatCut(scroller, { left: 600, top: 744, right: 800, bottom: 900 })).toBeUndefined();
});
