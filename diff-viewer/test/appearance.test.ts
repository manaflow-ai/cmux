import { describe, expect, test } from "bun:test";
import { appearanceBackgroundColor, resolveDiffViewerAppearance } from "../src/appearance";

describe("appearanceBackgroundColor", () => {
  test("applies Ghostty background opacity to hex colors", () => {
    expect(appearanceBackgroundColor("#102030", { backgroundOpacity: 0.42 })).toBe("rgb(16 32 48 / 0.42)");
  });

  test("clamps invalid opacity to opaque", () => {
    expect(appearanceBackgroundColor("#102030", { backgroundOpacity: 2 })).toBe("rgb(16 32 48 / 1)");
  });

  test("normalizes resolved opacity and metrics to rendered CSS values", () => {
    const appearance = resolveDiffViewerAppearance({
      backgroundOpacity: 2,
      fontSize: 0,
      lineHeight: -1,
    });

    expect(appearance.backgroundOpacity).toBe(1);
    expect(appearance.fontSize).toBe(10);
    expect(appearance.lineHeight).toBe(20);
  });
});
