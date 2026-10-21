import { expect, test } from "bun:test";
import {
  configureTurnActionsPlacement,
  turnActionsPlacementSnapshot,
} from "../src/agent-session/acpmux/turnActionsPlacement";

test("turn footer placement defaults left, under the answer, and only accepts the right opt-in", () => {
  configureTurnActionsPlacement(undefined);
  expect(turnActionsPlacementSnapshot()).toBe("left");
  configureTurnActionsPlacement("right");
  expect(turnActionsPlacementSnapshot()).toBe("right");
  configureTurnActionsPlacement("unexpected");
  expect(turnActionsPlacementSnapshot()).toBe("left");
});
