import { expect, test } from "bun:test";
import { configureTurnActionsPlacement, turnActionsPlacementSnapshot } from "../src/agent-session/acpmux/turnActionsPlacement";

test("turn footer placement defaults right and only accepts the left opt-in", () => {
  configureTurnActionsPlacement(undefined);
  expect(turnActionsPlacementSnapshot()).toBe("right");
  configureTurnActionsPlacement("left");
  expect(turnActionsPlacementSnapshot()).toBe("left");
  configureTurnActionsPlacement("unexpected");
  expect(turnActionsPlacementSnapshot()).toBe("right");
});
