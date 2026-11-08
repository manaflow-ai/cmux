import { describe, expect, it } from "vitest";
import { encodeTerminalKey, type TerminalKeyEvent } from "../src/lib/keyEncoding";

function key(value: string, overrides: Partial<TerminalKeyEvent> = {}): TerminalKeyEvent {
  return { key: value, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, ...overrides };
}

describe("render terminal key encoding", () => {
  it.each([
    [key("a"), { kind: "text", text: "a" }],
    [key("界"), { kind: "text", text: "界" }],
    [key("Enter"), { kind: "key", key: "enter" }],
    [key("ArrowLeft"), { kind: "key", key: "left" }],
    [key("Home"), { kind: "key", key: "home" }],
    [key("End", { ctrlKey: true }), { kind: "key", key: "ctrl+end" }],
    [key("Tab", { shiftKey: true }), { kind: "key", key: "backtab" }],
    [key("F12"), { kind: "key", key: "f12" }],
    [key("c", { ctrlKey: true }), { kind: "text", text: "\u0003" }],
    [key("[", { ctrlKey: true }), { kind: "text", text: "\u001b" }],
    [key("x", { altKey: true }), { kind: "text", text: "\u001bx" }],
    [key("c", { ctrlKey: true, altKey: true }), { kind: "text", text: "\u001b\u0003" }],
  ])("encodes $key", (event, expected) => {
    expect(encodeTerminalKey(event)).toEqual(expected);
  });

  it("leaves browser meta shortcuts and IME composition alone", () => {
    expect(encodeTerminalKey(key("c", { metaKey: true }))).toBeNull();
    expect(encodeTerminalKey(key("Process", { isComposing: true }))).toBeNull();
  });
});
