import { describe, expect, test } from "bun:test";
import { transcriptColumn } from "../model";
import { FLOAT_MARGIN, sessionInfoOverChat } from "./SessionInfo";
import { SESSION_INFO_WIDTH } from "./sessionInfoState";
import { SESSION_INFO_STACK_GAP, underSessionInfo, underSessionInfoRoom } from "./underSessionInfo";

/// The live preview card's width (computerUse/computerUsePreview.css).
const CARD_WIDTH = 180;
const column = { min: 720, max: 800, share: 0.625, prose: Infinity };

describe("underSessionInfo", () => {
  test("floating, the card sits the gap under the panel's foot, at the panel's right margin", () => {
    const place = underSessionInfo({ top: 44, height: 120, width: 320 }, 0, false, FLOAT_MARGIN);
    expect(place).toEqual({ top: 44 + 120 + SESSION_INFO_STACK_GAP, right: FLOAT_MARGIN });
    expect(SESSION_INFO_STACK_GAP).toBe(8);
  });

  test("pushing, the card reaches past the stage's edge by the panel's width, so its right edge is the panel's", () => {
    expect(underSessionInfo({ top: 44, height: 200, width: 320 }, 0, true, FLOAT_MARGIN)).toEqual({
      top: 252,
      right: -320,
    });
  });

  test("the top is in the stage's own box: a strip above the stage moves it up by its height", () => {
    expect(underSessionInfo({ top: 44, height: 120, width: 320 }, 36, false, FLOAT_MARGIN).top).toBe(136);
  });

  test("the card's room under the panel is its height and the gap, in whole px", () => {
    expect(underSessionInfoRoom(150.4)).toBe(158);
    expect(underSessionInfoRoom(0)).toBe(SESSION_INFO_STACK_GAP);
  });

  test("the card lies inside the panel's band, so where the gutter holds the panel it holds the card", () => {
    // The narrowest panel is wider than the card: right-aligned with it, the card never reaches past
    // its left edge.
    expect(SESSION_INFO_WIDTH.min).toBeGreaterThanOrEqual(CARD_WIDTH);
    for (const pane of [900, 1000, 1100, 1200, 1400, 1600]) {
      for (const width of [SESSION_INFO_WIDTH.min, SESSION_INFO_WIDTH.fallback, 400]) {
        if (sessionInfoOverChat(pane, width, column)) continue;
        // The column's end is clear of the card's left edge.
        expect(transcriptColumn(pane, column).inset).toBeGreaterThanOrEqual(FLOAT_MARGIN + CARD_WIDTH);
      }
    }
  });
});
