import { expect, test } from "bun:test";
import { isComposingEnter, isPlanModeShortcut } from "./keyboard";

test("composing enter is detected from browser and editor composition state", () => {
  expect(isComposingEnter({ key: "Enter", isComposing: true })).toBe(true);
  expect(isComposingEnter({ key: "Enter" }, true)).toBe(true);
  expect(isComposingEnter({ key: "Enter", keyCode: 229 })).toBe(true);
});

test("non-composing enter remains submittable", () => {
  expect(isComposingEnter({ key: "Enter" })).toBe(false);
  expect(isComposingEnter({ key: "a", isComposing: true })).toBe(false);
});

test("plan mode shortcut is Shift+Tab without other modifiers", () => {
  expect(isPlanModeShortcut({ key: "Tab", shiftKey: true })).toBe(true);
  expect(isPlanModeShortcut({ key: "Tab" })).toBe(false);
  expect(isPlanModeShortcut({ key: "Enter", shiftKey: true })).toBe(false);
  expect(isPlanModeShortcut({ key: "Tab", shiftKey: true, metaKey: true })).toBe(false);
  expect(isPlanModeShortcut({ key: "Tab", shiftKey: true, ctrlKey: true })).toBe(false);
  expect(isPlanModeShortcut({ key: "Tab", shiftKey: true, altKey: true })).toBe(false);
});
