import { describe, expect, test } from "bun:test";
import { inspectorPopover, POPOVER_BELOW_HEIGHT } from "./ChatInspector";

describe("inspectorPopover", () => {
  test("only over the chat in a short pane", () => {
    expect(inspectorPopover(POPOVER_BELOW_HEIGHT - 1, true)).toBe(true);
    expect(inspectorPopover(POPOVER_BELOW_HEIGHT, true)).toBe(false);
    expect(inspectorPopover(400, false)).toBe(false);
    // Unmeasured: never a popover.
    expect(inspectorPopover(0, true)).toBe(false);
  });
});
