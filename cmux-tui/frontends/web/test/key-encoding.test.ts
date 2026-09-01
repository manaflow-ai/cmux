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

  it("mirrors macOS line and cursor editing chords as raw control bytes", () => {
    expect([
      key("Backspace", { metaKey: true }),
      key("Delete", { metaKey: true }),
      key("ArrowLeft", { metaKey: true }),
      key("ArrowRight", { metaKey: true }),
    ].map(encodeTerminalKey)).toEqual([
      { kind: "text", text: "\u0015" },
      { kind: "text", text: "\u000b" },
      { kind: "text", text: "\u0001" },
      { kind: "text", text: "\u0005" },
    ]);
  });

  it("leaves browser shortcuts, modified selection, and IME composition alone", () => {
    for (const shortcut of ["c", "v", "w", "t", "q"]) {
      expect(encodeTerminalKey(key(shortcut, { metaKey: true }))).toBeNull();
    }
    for (const modifier of ["shiftKey", "altKey", "ctrlKey"] as const) {
      expect(encodeTerminalKey(key("Backspace", { metaKey: true, [modifier]: true }))).toBeNull();
    }
    expect(encodeTerminalKey(key("Process", { isComposing: true, metaKey: true }))).toBeNull();
  });
});
