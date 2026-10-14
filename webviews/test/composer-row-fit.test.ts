// The controls row's labels/icons switch must settle (hq#1957 item 15 review). With labels shown,
// a shortening label's overflow is read from scrollWidth - clientWidth, whole pixels, so a 0.4px
// squeeze counts as 1px and the row goes to icons; with icons shown the same row measures
// room + 0.4 and would go back. Each switch resizes the row and runs the check again: it must not
// flip every frame. Leaving icons needs clear room.
import { describe, expect, test } from "bun:test";
import { showsIcons } from "../src/agent-session/acpmux/composerRowFit";

describe("composer row fit", () => {
  const room = 400;

  test("labels give way when the row is over by more than half a pixel", () => {
    expect(showsIcons(false, room + 1, room)).toBe(true);
    expect(showsIcons(false, room + 0.4, room)).toBe(false);
  });

  test("icons stay through the sub-pixel band that sent the row to icons", () => {
    // Labels measured room + 1 (rounded), so the row is at icons; icons measure room + 0.4.
    expect(showsIcons(false, room + 1, room)).toBe(true);
    expect(showsIcons(true, room + 0.4, room)).toBe(true);
  });

  test("icons give way to labels once there is clear room", () => {
    expect(showsIcons(true, room - 1, room)).toBe(true);
    expect(showsIcons(true, room - 8, room)).toBe(false);
  });
});
