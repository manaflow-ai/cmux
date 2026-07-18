import { describe, expect, test } from "bun:test";
import { applyTerminalGridFrame } from "../services/share/terminalGrid";
import type { TerminalGridFrame } from "../services/share/protocol";

function frame(overrides: Partial<TerminalGridFrame> = {}): TerminalGridFrame {
  return {
    format: "cmux.render-grid.v1",
    surface_id: "surface-a",
    state_seq: 1,
    columns: 20,
    rows: 2,
    full: true,
    cleared_rows: [],
    styles: [{ id: 0, foreground: "ffffff" }],
    row_spans: [{ row: 0, column: 0, style_id: 0, text: "hello" }],
    ...overrides,
  };
}

describe("shared terminal grid", () => {
  test("applies row deltas without losing unchanged rows", () => {
    const initial = applyTerminalGridFrame(undefined, frame({
      row_spans: [
        { row: 0, column: 0, style_id: 0, text: "one" },
        { row: 1, column: 0, style_id: 0, text: "two" },
      ],
    }));
    expect(initial).not.toBeNull();
    const updated = applyTerminalGridFrame(initial!, frame({
      state_seq: 2,
      full: false,
      cleared_rows: [1],
      row_spans: [{ row: 1, column: 0, style_id: 0, text: "changed" }],
    }));
    expect(updated?.rowSpans[0]?.[0]?.text).toBe("one");
    expect(updated?.rowSpans[1]?.[0]?.text).toBe("changed");
  });

  test("requires a full frame after a sequence or dimension mismatch", () => {
    expect(applyTerminalGridFrame(undefined, frame({ full: false }))).toBeNull();
    const initial = applyTerminalGridFrame(undefined, frame())!;
    expect(applyTerminalGridFrame(initial, frame({ state_seq: 1, full: false, columns: 21 }))).toBeNull();
  });
});
