import { expect, test } from "bun:test";
import type { HatQuestion } from "./hatModel";
import { hatSeenKey, unseenHatQuestions } from "./hatSeen";

const question = (id: string, more: Partial<HatQuestion> = {}): HatQuestion => ({
  id,
  source: "child",
  prompt: id,
  answers: [],
  typed: false,
  ...more,
});

test("a dismissed question leaves the hat; the rest keep their order", () => {
  const list = [question("a"), question("b"), question("c")];
  const shown = unseenHatQuestions(list, new Set([hatSeenKey(list[1]!)]));
  expect(shown.map((each) => each.id)).toEqual(["a", "c"]);
});

test("nothing dismissed, or nothing of these, keeps the same list", () => {
  const list = [question("a")];
  expect(unseenHatQuestions(list, new Set())).toBe(list);
  expect(unseenHatQuestions(list, new Set(["hat\u0000other"]))).toBe(list);
});

test("a tagged ask shares its pinned card's key, so either dismissal puts both away", () => {
  const tagged = question("next:row-1", { source: "nextStep", answerKey: "123\u0000Can you?" });
  expect(hatSeenKey(tagged)).toBe("123\u0000Can you?");
  expect(unseenHatQuestions([tagged], new Set(["123\u0000Can you?"]))).toEqual([]);
});
