// The UI inspector's live label and hint (Leo, 2026-11-08: "you should be able to just see maybe some
// sort of preview as you're going and hovering"): where the label sits beside the outline and which
// edge the hint takes. The label never covers the element it names and stays on screen at every
// viewport edge; the hint leaves the edge the pointer, outline or label is at.
import { describe, expect, test } from "bun:test";
import {
  UI_POINTER_EDGE,
  UI_POINTER_LABEL_DENSITY,
  UI_POINTER_LABEL_PLACEMENT,
  hintEdge,
  placeLabel,
  type Box,
  type LabelPlacement,
} from "../src/agent-session/acpmux/uiPointer/labelModel";

const VIEW = { width: 480, height: 560 };
const LABEL = { width: 220, height: 52 };

const overlaps = (a: Box, b: Box) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

function expectOnScreen(box: Box) {
  expect(box.x).toBeGreaterThanOrEqual(UI_POINTER_EDGE);
  expect(box.y).toBeGreaterThanOrEqual(UI_POINTER_EDGE);
  expect(box.x + box.width).toBeLessThanOrEqual(VIEW.width - UI_POINTER_EDGE);
  expect(box.y + box.height).toBeLessThanOrEqual(VIEW.height - UI_POINTER_EDGE);
}

const TARGETS: Record<string, Box> = {
  middle: { x: 120, y: 200, width: 200, height: 40 },
  "top left": { x: 0, y: 0, width: 120, height: 30 },
  "top right": { x: 380, y: 0, width: 100, height: 30 },
  "bottom left": { x: 0, y: 530, width: 120, height: 30 },
  "bottom right": { x: 380, y: 530, width: 100, height: 30 },
  "full width": { x: 0, y: 240, width: 480, height: 40 },
};

describe("UI inspector label placement", () => {
  test("the default is the rich card above the outline", () => {
    expect(UI_POINTER_LABEL_DENSITY).toBe("card");
    expect(UI_POINTER_LABEL_PLACEMENT).toBe("above");
  });

  test("above when there is room, left-aligned with the element", () => {
    const placed = placeLabel(TARGETS.middle, LABEL, VIEW, "above");
    expect(placed.side).toBe("above");
    expect(placed.x).toBe(120);
    expect(placed.y + LABEL.height).toBeLessThanOrEqual(200);
  });

  test("flips below an element at the top edge", () => {
    expect(placeLabel(TARGETS["top left"], LABEL, VIEW, "above").side).toBe("below");
  });

  for (const placement of ["above", "below", "side"] as LabelPlacement[])
    for (const [name, target] of Object.entries(TARGETS))
      test(`${placement}: on screen and clear of the element at ${name}`, () => {
        const placed = placeLabel(target, LABEL, VIEW, placement);
        const box = { x: placed.x, y: placed.y, ...LABEL };
        expectOnScreen(box);
        expect(overlaps(box, target)).toBe(false);
      });

  test("an element taller than the viewport still keeps the label on screen", () => {
    const placed = placeLabel({ x: -20, y: -100, width: 600, height: 900 }, LABEL, VIEW, "above");
    expectOnScreen({ x: placed.x, y: placed.y, ...LABEL });
  });

  test("a label wider than the viewport starts at the left edge", () => {
    const placed = placeLabel(TARGETS.middle, { width: 600, height: 40 }, VIEW, "above");
    expect(placed.x).toBe(UI_POINTER_EDGE);
  });
});

describe("UI inspector hint edge", () => {
  const HINT = { width: 300, height: 28 };
  test("the top edge by default", () => {
    expect(hintEdge(HINT, VIEW, [TARGETS.middle])).toBe("top");
  });
  test("the bottom edge when the pointer, outline or label is at the top", () => {
    expect(hintEdge(HINT, VIEW, [{ x: 200, y: 10, width: 1, height: 1 }])).toBe("bottom");
    expect(hintEdge(HINT, VIEW, [{ x: 140, y: 0, width: 200, height: 30 }])).toBe("bottom");
  });
  test("the top edge when both edges are covered", () => {
    expect(hintEdge(HINT, VIEW, [{ x: 0, y: 0, width: 480, height: 560 }])).toBe("top");
  });
});
