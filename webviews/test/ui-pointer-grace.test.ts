// Inspect Element's grace (Leo, 2026-11-08: "there's a grace period right after clicking inspect
// element, and ... when you haven't moved your mouse, where it should just be, like, okay, it's
// there"): the right-clicked element holds until the grace time has passed and the pointer is a
// deliberate distance from its first position after the menu. The clock is the test's own.
import { describe, expect, test } from "bun:test";
import {
  UI_POINTER_GRACE_MS,
  UI_POINTER_MOVE_PX,
  graceAfterMove,
  startGrace,
} from "../src/agent-session/acpmux/uiPointer/grace";

describe("Inspect Element grace", () => {
  test("the values are a brief half second and a deliberate 16 px", () => {
    expect(UI_POINTER_GRACE_MS).toBe(500);
    expect(UI_POINTER_MOVE_PX).toBe(16);
  });

  test("the first move after the menu sets the origin, however far it is from the right-click", () => {
    const grace = graceAfterMove(startGrace(0), 600, 400, 300);
    expect(grace).toEqual({ since: 0, origin: { x: 400, y: 300 } });
  });

  test("a big move inside the grace time keeps the hold", () => {
    let grace = graceAfterMove(startGrace(0), 50, 100, 100);
    grace = grace && graceAfterMove(grace, UI_POINTER_GRACE_MS - 1, 300, 300);
    expect(grace).not.toBeNull();
  });

  test("after the grace time, a move under the threshold keeps the hold", () => {
    let grace = graceAfterMove(startGrace(0), 50, 100, 100);
    grace = grace && graceAfterMove(grace, UI_POINTER_GRACE_MS + 400, 100 + UI_POINTER_MOVE_PX - 1, 100);
    expect(grace).not.toBeNull();
  });

  test("after the grace time, a deliberate move releases the hold", () => {
    let grace = graceAfterMove(startGrace(0), 50, 100, 100);
    grace = grace && graceAfterMove(grace, UI_POINTER_GRACE_MS, 100, 100 + UI_POINTER_MOVE_PX);
    expect(grace).toBeNull();
  });
});
