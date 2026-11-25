import { beforeEach, describe, expect, test } from "bun:test";

import { hasPromptTops, keepPromptTops, knownPromptTop, resetPromptTops } from "./transcriptHeights";

describe("transcriptHeights", () => {
  beforeEach(() => resetPromptTops());

  test("a chat held whole keeps each prompt's top, at its width only", () => {
    keepPromptTops("s", 640, [
      { id: "u1", top: 0 },
      { id: "u2", top: 1234.5 },
    ]);
    expect(hasPromptTops("s", 640)).toBe(true);
    expect(knownPromptTop("s", 640, "u2")).toBe(1234.5);
    // Another width lays the chat out at other heights: nothing is known there.
    expect(hasPromptTops("s", 900)).toBe(false);
    expect(knownPromptTop("s", 900, "u2")).toBeUndefined();
    expect(knownPromptTop("other", 640, "u2")).toBeUndefined();
    expect(knownPromptTop(undefined, 640, "u2")).toBeUndefined();
  });

  test("a later visit replaces the chat's tops, and the least recent chats go past the cap", () => {
    keepPromptTops("s", 640, [{ id: "u1", top: 10 }]);
    keepPromptTops("s", 640, [{ id: "u1", top: 20 }]);
    expect(knownPromptTop("s", 640, "u1")).toBe(20);
    for (let chat = 0; chat < 8; chat += 1) keepPromptTops(`c${chat}`, 640, [{ id: "u1", top: chat }]);
    expect(hasPromptTops("s", 640)).toBe(false);
    expect(knownPromptTop("c7", 640, "u1")).toBe(7);
  });
});
