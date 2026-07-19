import { describe, expect, test } from "bun:test";

import { TerminalGridModel } from "../app/[locale]/share/[code]/terminal-grid";
import { keyEventToBytes } from "../app/[locale]/share/[code]/terminal-keys";
import { spliceDiff } from "../app/[locale]/share/[code]/shared-composer";
import type { RenderGridFrame } from "../app/[locale]/share/[code]/share-protocol";

function fullFrame(overrides: Partial<RenderGridFrame> = {}): RenderGridFrame {
  return {
    format: "cmux.render-grid.v1",
    surface_id: "s-1",
    state_seq: 1,
    columns: 10,
    rows: 3,
    full: true,
    styles: [{ id: 0 }],
    row_spans: [
      { row: 0, column: 0, style_id: 0, text: "hello" },
      { row: 1, column: 2, style_id: 0, text: "world" },
    ],
    cursor: { row: 1, column: 7 },
    terminal_background: "1e1e2e",
    terminal_foreground: "cdd6f4",
    ...overrides,
  };
}

describe("TerminalGridModel", () => {
  test("applies a full frame and reads theme colors", () => {
    const model = new TerminalGridModel();
    expect(model.apply(fullFrame())).toBe(true);
    expect(model.ready).toBe(true);
    expect(model.cols).toBe(10);
    expect(model.background).toBe("#1e1e2e");
    expect(model.rowSpans(0)[0]?.text).toBe("hello");
    expect(model.cursor?.column).toBe(7);
  });

  test("rejects deltas before any full frame", () => {
    const model = new TerminalGridModel();
    expect(model.apply(fullFrame({ full: false, cleared_rows: [0], row_spans: [] }))).toBe(false);
  });

  test("delta clears rows then repaints the spans it carries", () => {
    const model = new TerminalGridModel();
    model.apply(fullFrame());
    const ok = model.apply(
      fullFrame({
        full: false,
        cleared_rows: [0, 1],
        row_spans: [{ row: 1, column: 0, style_id: 0, text: "changed" }],
        cursor: { row: 0, column: 0 },
      }),
    );
    expect(ok).toBe(true);
    expect(model.rowSpans(0)).toEqual([]);
    expect(model.rowSpans(1)[0]?.text).toBe("changed");
  });

  test("rejects wrong formats and geometry-changing deltas", () => {
    const model = new TerminalGridModel();
    expect(model.apply(fullFrame({ format: "cmux.render-grid.v2" }))).toBe(false);
    model.apply(fullFrame());
    expect(model.apply(fullFrame({ full: false, columns: 12 }))).toBe(false);
  });
});

describe("spliceDiff", () => {
  test("insert, delete, replace, and noop", () => {
    expect(spliceDiff("abc", "abc")).toBeNull();
    expect(spliceDiff("abc", "abXc")).toEqual({ p: 2, d: 0, i: "X" });
    expect(spliceDiff("abXc", "abc")).toEqual({ p: 2, d: 1, i: "" });
    expect(spliceDiff("hello", "help")).toEqual({ p: 3, d: 2, i: "p" });
    expect(spliceDiff("", "hi")).toEqual({ p: 0, d: 0, i: "hi" });
  });

  test("handles multi-codepoint characters as single units", () => {
    expect(spliceDiff("a🙂b", "ab")).toEqual({ p: 1, d: 1, i: "" });
  });
});

describe("keyEventToBytes", () => {
  const key = (k: string, mods: Partial<Record<"ctrlKey" | "altKey" | "metaKey" | "shiftKey", boolean>> = {}) =>
    keyEventToBytes({ key: k, ctrlKey: false, altKey: false, metaKey: false, shiftKey: false, ...mods });

  test("printables, enter, backspace, arrows", () => {
    expect(key("a")).toBe("a");
    expect(key("Enter")).toBe("\r");
    expect(key("Backspace")).toBe("\x7f");
    expect(key("ArrowUp")).toBe("\x1b[A");
    expect(key("ArrowLeft", { shiftKey: true })).toBe("\x1b[1;2D");
  });

  test("control combos and meta passthrough", () => {
    expect(key("c", { ctrlKey: true })).toBe("\x03");
    expect(key("c", { metaKey: true })).toBeNull();
    expect(key("Shift")).toBeNull();
  });
});
