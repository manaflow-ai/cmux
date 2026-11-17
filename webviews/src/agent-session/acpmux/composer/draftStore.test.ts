import { expect, test } from "bun:test";
import { createComposerDraftStore, sameTrigger } from "./draftStore";

test("the draft starts at the text given, caret at its end", () => {
  expect(createComposerDraftStore("hi there").get()).toEqual({ text: "hi there", caret: 8 });
});

test("a write tells every listener once, and the draft it leaves is one object", () => {
  const store = createComposerDraftStore("");
  const seen: string[] = [];
  store.subscribe(() => seen.push(`a:${store.get().text}`));
  store.subscribe(() => seen.push(`b:${store.get().text}`));
  store.write("a", 1);
  store.write("ab", 2);
  expect(seen).toEqual(["a:a", "b:a", "a:ab", "b:ab"]);
  const held = store.get();
  expect(store.get()).toBe(held);
});

test("a write of the same text and caret tells nobody, so an unchanged field renders nothing", () => {
  const store = createComposerDraftStore("ab");
  let told = 0;
  store.subscribe(() => (told += 1));
  store.write("ab", 2);
  expect(told).toBe(0);
  store.writeCaret(2);
  expect(told).toBe(0);
  // The caret alone moving is a change: a picker reads the word at the caret.
  store.writeCaret(1);
  expect(told).toBe(1);
  expect(store.get()).toEqual({ text: "ab", caret: 1 });
});

test("a listener that leaves while the write is told does not drop the one after it", () => {
  const store = createComposerDraftStore("");
  const seen: string[] = [];
  const off = store.subscribe(() => {
    seen.push("first");
    off();
  });
  store.subscribe(() => seen.push("second"));
  store.write("a", 1);
  expect(seen).toEqual(["first", "second"]);
  store.write("ab", 2);
  expect(seen).toEqual(["first", "second", "second"]);
});

test("unsubscribing stops the listener", () => {
  const store = createComposerDraftStore("");
  let told = 0;
  const off = store.subscribe(() => (told += 1));
  store.write("a", 1);
  off();
  store.write("ab", 2);
  expect(told).toBe(1);
});

test("a picker's trigger recomputed the same way reads as unchanged", () => {
  expect(sameTrigger(undefined, undefined)).toBe(true);
  expect(sameTrigger({ start: 3, query: "te" }, { start: 3, query: "te" })).toBe(true);
  expect(sameTrigger({ start: 3, query: "te" }, { start: 3, query: "ted" })).toBe(false);
  expect(sameTrigger({ start: 3, query: "te" }, undefined)).toBe(false);
  expect(sameTrigger(undefined, { start: 3, query: "te" })).toBe(false);
  // A field more or fewer is a change, whichever side it is on.
  expect(sameTrigger({ start: 3 } as { start: number; query?: string }, { start: 3, query: "te" })).toBe(false);
  expect(sameTrigger({ start: 3, query: "te" }, { start: 3 } as { start: number; query?: string })).toBe(false);
});
