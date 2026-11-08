import { describe, expect, test } from "bun:test";
import { focusAfter, keyAction, type KeyLike } from "./keys";
import type { DialogKeys } from "./types";

const keys: DialogKeys = { return: "save", escape: "cancel", command: { d: "discard" } };
const press = (key: string, mods: Partial<KeyLike> = {}): KeyLike => ({
  key,
  metaKey: false,
  ctrlKey: false,
  altKey: false,
  shiftKey: false,
  ...mods,
});

describe("dialog keys follow CmuxDialogKeys", () => {
  test("Return presses the default, with or without Command or Shift", () => {
    expect(keyAction(press("Enter"), keys)).toEqual({ press: "save" });
    expect(keyAction(press("Enter", { metaKey: true }), keys)).toEqual({ press: "save" });
    expect(keyAction(press("Enter", { shiftKey: true }), keys)).toEqual({ press: "save" });
    expect(keyAction(press("Enter", { ctrlKey: true }), keys)).toBeNull();
    expect(keyAction(press("Enter"), { command: {} })).toBeNull();
  });

  test("Escape and Command-period press the cancel button", () => {
    expect(keyAction(press("Escape"), keys)).toEqual({ press: "cancel" });
    expect(keyAction(press(".", { metaKey: true }), keys)).toEqual({ press: "cancel" });
  });

  test("Command plus a button's key presses it, any case; plain letters type", () => {
    expect(keyAction(press("d", { metaKey: true }), keys)).toEqual({ press: "discard" });
    expect(keyAction(press("D", { metaKey: true, shiftKey: true }), keys)).toEqual({ press: "discard" });
    expect(keyAction(press("d"), keys)).toBeNull();
    expect(keyAction(press("x", { metaKey: true }), keys)).toBeNull();
  });

  test("Tab and Shift-Tab move the focus; Command-Tab is the system's", () => {
    expect(keyAction(press("Tab"), keys)).toEqual({ focus: "next" });
    expect(keyAction(press("Tab", { shiftKey: true }), keys)).toEqual({ focus: "previous" });
    expect(keyAction(press("Tab", { metaKey: true }), keys)).toBeNull();
  });

  test("focus wraps at both ends and starts at an end", () => {
    expect(focusAfter(-1, 3, false)).toBe(0);
    expect(focusAfter(-1, 3, true)).toBe(2);
    expect(focusAfter(2, 3, false)).toBe(0);
    expect(focusAfter(0, 3, true)).toBe(2);
    expect(focusAfter(0, 0, false)).toBe(-1);
  });
});
