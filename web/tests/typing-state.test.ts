import { test, expect } from "bun:test";
import { reduceTypingState, type TypingState } from "../app/[locale]/typing-state";

const deletingState: TypingState = {
  phraseIndex: 0,
  charIndex: 2,
  deleting: true,
};

test("finishing deletion advances and resets the animation in one transition", () => {
  expect(
    reduceTypingState(deletingState, { type: "finish-deleting", phraseCount: 3 }),
  ).toEqual({
    phraseIndex: 1,
    charIndex: 0,
    deleting: false,
  });
});
