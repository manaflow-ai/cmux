import { expect, test } from "bun:test";
import { BodyCache, bodyTokens, cachedDrawing } from "./bodyCache";

test("a body's text is parsed once and served to every later read", () => {
  const cache = new BodyCache<number>(4, 1000);
  let made = 0;
  const make = () => (made += 1);
  expect(cache.read("a", make)).toBe(1);
  expect(cache.read("a", make)).toBe(1);
  expect(made).toBe(1);
});

test("the least recently read body leaves first, past the entry bound", () => {
  const cache = new BodyCache<string>(2, 1000);
  cache.read("a", (k) => k);
  cache.read("b", (k) => k);
  cache.read("a", (k) => k);
  cache.read("c", (k) => k);
  let remade = "";
  cache.read("b", (k) => (remade = k));
  expect(remade).toBe("b");
  expect(cache.size).toBe(2);
});

test("the character bound holds, and a body past it is parsed but not kept", () => {
  const cache = new BodyCache<number>(100, 10);
  cache.read("12345", () => 1);
  cache.read("67890", () => 2);
  cache.read("abc", () => 3);
  expect(cache.size).toBe(2);
  cache.read("x".repeat(11), () => 4);
  expect(cache.size).toBe(2);
});

test("bodyTokens is marked's GFM lexing, the same array for the same text", () => {
  const first = bodyTokens("| a |\n|---|\n| 1 |\n\n- [x] done");
  expect(first.map((token) => token.type)).toEqual(["table", "list"]);
  expect(bodyTokens("| a |\n|---|\n| 1 |\n\n- [x] done")).toBe(first);
});

test("a drawing is kept per opener", () => {
  const openA = () => {};
  const openB = () => {};
  let draws = 0;
  const draw = () => {
    draws += 1;
    return [];
  };
  void cachedDrawing("<p>x</p>", openA, draw);
  void cachedDrawing("<p>x</p>", openA, draw);
  void cachedDrawing("<p>x</p>", openB, draw);
  expect(draws).toBe(2);
});
