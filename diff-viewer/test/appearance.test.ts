import { describe, expect, test } from "bun:test";
import { appearanceBackgroundColor } from "../src/appearance";

describe("appearanceBackgroundColor", () => {
  test("applies Ghostty background opacity to hex colors", () => {
    expect(appearanceBackgroundColor("#102030", { backgroundOpacity: 0.42 })).toBe("rgb(16 32 48 / 0.42)");
  });

  test("clamps invalid opacity to opaque", () => {
    expect(appearanceBackgroundColor("#102030", { backgroundOpacity: 2 })).toBe("rgb(16 32 48 / 1)");
  });
});
