import { expect, test } from "bun:test";
import {
  shouldAutoFocusTerminal,
  shouldFocusTerminalFromPointer,
  shouldSuppressMouseFocusAfterTouch,
} from "./terminalPointerFocus";

test("does not focus terminal input from touch pointer events", () => {
  expect(shouldFocusTerminalFromPointer("touch")).toBe(false);
});

test("allows direct terminal focus for mouse and pen pointer events", () => {
  expect(shouldFocusTerminalFromPointer("mouse")).toBe(true);
  expect(shouldFocusTerminalFromPointer("pen")).toBe(true);
  expect(shouldFocusTerminalFromPointer(undefined)).toBe(true);
});

test("skips automatic terminal focus on coarse touch devices", () => {
  expect(shouldAutoFocusTerminal(true, 5)).toBe(false);
  expect(shouldAutoFocusTerminal(false, 1)).toBe(false);
  expect(shouldAutoFocusTerminal(false, 0)).toBe(true);
});

test("suppresses compatibility mouse focus shortly after touch", () => {
  expect(shouldSuppressMouseFocusAfterTouch(100, 100)).toBe(true);
  expect(shouldSuppressMouseFocusAfterTouch(100, 899)).toBe(true);
  expect(shouldSuppressMouseFocusAfterTouch(100, 900)).toBe(true);
});

test("allows normal mouse focus outside the touch suppression window", () => {
  expect(shouldSuppressMouseFocusAfterTouch(0, 100)).toBe(false);
  expect(shouldSuppressMouseFocusAfterTouch(100, 901)).toBe(false);
  expect(shouldSuppressMouseFocusAfterTouch(200, 100)).toBe(false);
});
