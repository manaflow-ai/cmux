import { describe, expect, test } from "bun:test";
import { appearanceBackgroundColor, resolveDiffViewerAppearance } from "../src/appearance";

describe("appearanceBackgroundColor", () => {
  test("returns transparent for transparent themes so the window backdrop shows", () => {
    expect(appearanceBackgroundColor("#102030", { backgroundOpacity: 0.42 })).toBe("transparent");
  });

  test("returns a solid fill for opaque themes", () => {
    expect(appearanceBackgroundColor("#102030", { backgroundOpacity: 1 })).toBe("#102030");
  });

  test("clamps invalid opacity to opaque and paints a solid fill", () => {
    expect(appearanceBackgroundColor("#102030", { backgroundOpacity: 2 })).toBe("#102030");
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
