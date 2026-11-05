// Find in Chat's bar keeps left of Session Info in every stage (Leo, 2026-11-03: "oh no the command f
// overlaps with the session info.."): the bar's right edge, the chat's right edge less the panel's reach
// (sessionInfoClear) and the bar's inset, is never right of the panel's left edge.
import { describe, expect, test } from "bun:test";
import {
  FIND_BAR_INSET,
  FIND_BAR_MIN,
  FLOAT_MARGIN,
  findBarCramped,
  pushedRoom,
  pushedWidth,
  sessionInfoClear,
  sessionInfoStage,
} from "./SessionInfo";
import { SESSION_INFO_WIDTH } from "./sessionInfoState";

const column = { min: 720, max: 800 };
const width = SESSION_INFO_WIDTH.fallback;

/// The panel's left edge and the bar's right edge, in px from the pane's left, as the page lays them out:
/// the panel `FLOAT_MARGIN` from the pane's right edge, the chat the pane less a push's room.
function place(pane: number) {
  const stage = sessionInfoStage("overlay", { width: pane, height: 900 }, width, column);
  const panel = stage === "push" ? pushedWidth(pane, width) : width;
  const room = stage === "push" ? pushedRoom(pane, panel, column) : 0;
  const clear = sessionInfoClear(panel, room);
  return {
    stage,
    clear,
    cramped: findBarCramped(pane - room, clear),
    panelLeft: pane - FLOAT_MARGIN - panel,
    barRight: pane - room - clear - FIND_BAR_INSET,
    barRoom: pane - room - clear - 2 * FIND_BAR_INSET,
  };
}

describe("Find in Chat's bar beside Session Info", () => {
  test("floating in the gutter, pushing and over the chat, the bar ends the inset left of the panel", () => {
    const stages = new Set<string>();
    for (const pane of [1600, 1400, 1200, 1100, 900, 740]) {
      const at = place(pane);
      stages.add(at.stage);
      expect(at.barRight).toBe(at.panelLeft - FIND_BAR_INSET);
      expect(at.cramped).toBe(false);
      expect(at.barRoom).toBeGreaterThanOrEqual(FIND_BAR_MIN);
    }
    expect([...stages].sort()).toEqual(["float", "overlay", "push"]);
  });

  test("the panel's reach is its width and margin less a push's room, never negative", () => {
    expect(sessionInfoClear(320, 0)).toBe(320 + FLOAT_MARGIN);
    expect(sessionInfoClear(320, 100)).toBe(228);
    expect(sessionInfoClear(320, 328)).toBe(0);
    expect(sessionInfoClear(320, 400)).toBe(0);
  });

  test("an off-grid dragged width keeps the chat flush with the panel", () => {
    const panel = 300;
    const room = pushedRoom(1300, panel, column, 0, true);
    expect(room).toBe(panel + FLOAT_MARGIN);
    expect(sessionInfoClear(panel, room)).toBe(0);
  });

  test("a chat with no room for the bar's narrowest beside the panel is cramped; unmeasured is not", () => {
    expect(place(528).cramped).toBe(true);
    expect(place(370).cramped).toBe(true);
    expect(findBarCramped(0, 328)).toBe(false);
    expect(findBarCramped(328 + FIND_BAR_MIN + 2 * FIND_BAR_INSET, 328)).toBe(false);
    expect(findBarCramped(328 + FIND_BAR_MIN + 2 * FIND_BAR_INSET - 1, 328)).toBe(true);
  });
});
