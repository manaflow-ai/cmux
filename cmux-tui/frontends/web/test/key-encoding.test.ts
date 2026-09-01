import { describe, expect, it } from "vitest";
import {
  browserIsMacPlatform,
  encodeTerminalKey,
  isMacEditingChord,
  type TerminalKeyEvent,
} from "../src/lib/keyEncoding";

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
    ].map((event) => encodeTerminalKey(event, { macEditing: true }))).toEqual([
      { kind: "text", text: "\u0015" },
      { kind: "text", text: "\u000b" },
      { kind: "text", text: "\u0001" },
      { kind: "text", text: "\u0005" },
    ]);
  });

  it("mirrors macOS Option word editing chords without swallowing normal Option text", () => {
    expect([
      key("Backspace", { altKey: true }),
      key("Delete", { altKey: true }),
      key("ArrowLeft", { altKey: true }),
      key("ArrowRight", { altKey: true }),
    ].map((event) => encodeTerminalKey(event, { macEditing: true }))).toEqual([
      { kind: "text", text: "\u001b\u007f" },
      { kind: "text", text: "\u001bd" },
      { kind: "text", text: "\u001bb" },
      { kind: "text", text: "\u001bf" },
    ]);
    expect(encodeTerminalKey(key("x", { altKey: true }))).toEqual({
      kind: "text",
      text: "\u001bx",
    });
    expect(isMacEditingChord(key("Backspace", { altKey: true }), { macEditing: true })).toBe(true);
    expect(isMacEditingChord(key("x", { altKey: true }), { macEditing: true })).toBe(false);
  });

  it("keeps non-macOS Alt editing keys on the generic named-key path", () => {
    expect([
      key("Backspace", { altKey: true }),
      key("Delete", { altKey: true }),
      key("ArrowLeft", { altKey: true }),
      key("ArrowRight", { altKey: true }),
    ].map((event) => encodeTerminalKey(event, { macEditing: false }))).toEqual([
      { kind: "key", key: "alt+backspace" },
      { kind: "key", key: "alt+delete" },
      { kind: "key", key: "alt+left" },
      { kind: "key", key: "alt+right" },
    ]);
    expect(isMacEditingChord(key("Backspace", { altKey: true }), { macEditing: false })).toBe(false);
  });

  it("leaves browser shortcuts, modified selection, and IME composition alone", () => {
    for (const shortcut of ["c", "v", "w", "t", "q"]) {
      expect(encodeTerminalKey(key(shortcut, { metaKey: true }))).toBeNull();
    }
    for (const modifier of ["shiftKey", "altKey", "ctrlKey"] as const) {
      expect(encodeTerminalKey(key("Backspace", { metaKey: true, [modifier]: true }))).toBeNull();
    }
    for (const modifier of ["shiftKey", "metaKey", "ctrlKey"] as const) {
      const event = key("Backspace", { altKey: true, [modifier]: true });
      expect(isMacEditingChord(event)).toBe(false);
    }
    expect(encodeTerminalKey(key("Process", { isComposing: true, metaKey: true }), { macEditing: true })).toBeNull();
    expect(isMacEditingChord(key("Backspace", { altKey: true, isComposing: true }), { macEditing: true })).toBe(false);
  });

  it("recognizes macOS browser platform identifiers", () => {
    expect(browserIsMacPlatform({ userAgentData: { platform: "macOS" } })).toBe(true);
    expect(browserIsMacPlatform({ userAgentData: { platform: "" }, platform: "MacIntel" })).toBe(true);
    expect(browserIsMacPlatform({ platform: "MacIntel" })).toBe(true);
    expect(browserIsMacPlatform({ userAgent: "Mozilla/5.0 (X11; Linux x86_64)" })).toBe(false);
    expect(browserIsMacPlatform({ platform: "Win32" })).toBe(false);
  });
});
