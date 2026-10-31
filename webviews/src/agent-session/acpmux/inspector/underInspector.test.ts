import { describe, expect, test } from "bun:test";
import { transcriptColumn } from "../model";
import { FLOAT_MARGIN, inspectorOverChat } from "./ChatInspector";
import { INSPECTOR_WIDTH } from "./inspectorState";
import { INSPECTOR_STACK_GAP, underInspector, underInspectorRoom } from "./underInspector";

/// The live preview card's width (computerUse/computerUsePreview.css).
const CARD_WIDTH = 180;
const column = { min: 720, max: 800, share: 0.625, prose: Infinity };

describe("underInspector", () => {
  test("floating, the card sits the gap under the panel's foot, at the panel's right margin", () => {
    const place = underInspector({ top: 44, height: 120, width: 320 }, 0, false, FLOAT_MARGIN);
    expect(place).toEqual({ top: 44 + 120 + INSPECTOR_STACK_GAP, right: FLOAT_MARGIN });
    expect(INSPECTOR_STACK_GAP).toBe(8);
  });

  test("pushing, the card reaches past the stage's edge by the panel's width, so its right edge is the panel's", () => {
    expect(underInspector({ top: 44, height: 200, width: 320 }, 0, true, FLOAT_MARGIN)).toEqual({
      top: 252,
      right: -320,
    });
  });

  test("the top is in the stage's own box: a strip above the stage moves it up by its height", () => {
    expect(underInspector({ top: 44, height: 120, width: 320 }, 36, false, FLOAT_MARGIN).top).toBe(136);
  });

  test("the card's room under the panel is its height and the gap, in whole px", () => {
    expect(underInspectorRoom(150.4)).toBe(158);
    expect(underInspectorRoom(0)).toBe(INSPECTOR_STACK_GAP);
  });

  test("the card lies inside the panel's band, so where the gutter holds the panel it holds the card", () => {
    // The narrowest panel is wider than the card: right-aligned with it, the card never reaches past
    // its left edge.
    expect(INSPECTOR_WIDTH.min).toBeGreaterThanOrEqual(CARD_WIDTH);
    for (const pane of [900, 1000, 1100, 1200, 1400, 1600]) {
      for (const width of [INSPECTOR_WIDTH.min, INSPECTOR_WIDTH.fallback, 400]) {
        if (inspectorOverChat(pane, width, column)) continue;
        // The column's end is clear of the card's left edge.
        expect(transcriptColumn(pane, column).inset).toBeGreaterThanOrEqual(FLOAT_MARGIN + CARD_WIDTH);
      }
    }
  });
});
