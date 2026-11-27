import { expect, test } from "bun:test";
import { shouldScrollToBottomAfterSend } from "./sendScrollSetting";

test("the default keeps today's send-to-latest behavior", () => {
  expect(shouldScrollToBottomAfterSend(true, false)).toBe(true);
});

test("disabled send-to-bottom preserves an up-scroll anchor", () => {
  expect(shouldScrollToBottomAfterSend(false, false)).toBe(false);
});

test("disabled send-to-bottom still follows streaming at the bottom", () => {
  expect(shouldScrollToBottomAfterSend(false, true)).toBe(true);
});
