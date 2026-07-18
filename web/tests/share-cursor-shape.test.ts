import { describe, expect, test } from "bun:test";
import {
  SHARE_CURSOR_PATH_DATA,
  SHARE_CURSOR_SCALE,
  SHARE_CURSOR_STROKE_WIDTH,
  SHARE_CURSOR_VIEW_BOX,
} from "../services/share/cursorShape";

describe("shared cursor shape", () => {
  test("matches Austin's Sky computer-use cursor", () => {
    expect(SHARE_CURSOR_VIEW_BOX).toBe("0 0 24 30");
    expect(SHARE_CURSOR_SCALE).toBe(1.5);
    expect(SHARE_CURSOR_STROKE_WIDTH).toBe(1.7);
    expect(SHARE_CURSOR_PATH_DATA).toBe(
      "M0.68 1.83 L3.63 9.78 Q4.67 12.59 5.3 9.66 L5.44 9.01 Q6.08 6.08 9.01 5.44 L9.66 5.3 Q12.59 4.67 9.78 3.63 L1.83 0.68 Q0 0 0.68 1.83 Z",
    );
  });
});
