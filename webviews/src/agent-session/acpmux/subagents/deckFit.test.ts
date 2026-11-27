import { expect, test } from "bun:test";
import { DECK_FIT_STEPS, deckLevelAt, deckMarksAt } from "./deckFit";

test("the deck gives up a form at each step and keeps the richest while unmeasured", () => {
  expect(deckLevelAt(0)).toBe(0);
  expect(deckLevelAt(900)).toBe(0);
  expect(deckLevelAt(DECK_FIT_STEPS.stacked)).toBe(1);
  expect(deckLevelAt(DECK_FIT_STEPS.few)).toBe(2);
  expect(deckLevelAt(DECK_FIT_STEPS.wordsOnly)).toBe(3);
  expect(deckLevelAt(280)).toBe(3);
});

test("each level caps its marks, never more than the lines or the deck's cap", () => {
  expect(deckMarksAt(0, 14, 8)).toBe(8);
  expect(deckMarksAt(1, 14, 8)).toBe(5);
  expect(deckMarksAt(2, 14, 8)).toBe(3);
  expect(deckMarksAt(3, 14, 8)).toBe(0);
  expect(deckMarksAt(1, 2, 8)).toBe(2);
});
