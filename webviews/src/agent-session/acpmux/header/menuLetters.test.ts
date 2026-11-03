import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { menuLetter, TYPEAHEAD_MS, type MenuTyping } from "./menuLetters";

const dom = new JSDOM(`<div role="menu" tabindex="-1"><input type="search"><textarea></textarea>
  <div contenteditable="true"></div><button role="menuitem">Rename</button></div>`);
const doc = dom.window.document;
const at = (selector: string) => doc.querySelector(selector)!;
const key = (target: Element, letter: string, extra: Record<string, unknown> = {}) => ({
  key: letter,
  metaKey: false,
  ctrlKey: false,
  altKey: false,
  target,
  ...extra,
});

test("a first letter in the menu is a row letter", () => {
  const typing: MenuTyping = { last: 0 };
  expect(menuLetter(key(at('[role="menuitem"]'), "r"), typing, 10_000)).toBe("R");
});

test("a letter that continues the typeahead is the typeahead's, never a row's", () => {
  const typing: MenuTyping = { last: 0 };
  const row = at('[role="menuitem"]');
  // "tr" for Transcript view, "ma" for Mark as Unread: the second key never renames or archives.
  expect(menuLetter(key(row, "t"), typing, 10_000)).toBe("T");
  expect(menuLetter(key(row, "r"), typing, 10_100)).toBeUndefined();
  expect(menuLetter(key(row, "m"), typing, 20_000)).toBe("M");
  expect(menuLetter(key(row, "a"), typing, 20_000 + TYPEAHEAD_MS - 1)).toBeUndefined();
  // A pause ends the sequence.
  expect(menuLetter(key(row, "f"), typing, 30_000)).toBe("F");
});

test("a key typed into a field, an editor or a composition is text", () => {
  for (const selector of ['input[type="search"]', "textarea", "[contenteditable]"]) {
    expect(menuLetter(key(at(selector), "r"), { last: 0 }, 10_000)).toBeUndefined();
  }
  expect(menuLetter(key(at('[role="menuitem"]'), "r", { isComposing: true }), { last: 0 }, 10_000)).toBeUndefined();
  expect(
    menuLetter(key(at('[role="menuitem"]'), "a", { nativeEvent: { isComposing: true } }), { last: 0 }, 10_000),
  ).toBeUndefined();
});

test("modified keys and non-letters are not row letters", () => {
  const row = at('[role="menuitem"]');
  for (const extra of [{ metaKey: true }, { ctrlKey: true }, { altKey: true }])
    expect(menuLetter(key(row, "r", extra), { last: 0 }, 10_000)).toBeUndefined();
  expect(menuLetter(key(row, "1"), { last: 0 }, 10_000)).toBeUndefined();
  expect(menuLetter(key(row, "Enter"), { last: 0 }, 10_000)).toBeUndefined();
});
