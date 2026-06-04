import { describe, expect, test } from "bun:test";
import { appearanceBackgroundColor, readableColor, resolveDiffViewerAppearance } from "../src/appearance";

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

  test("keeps resolved foregrounds readable against their backgrounds", () => {
    const appearance = resolveDiffViewerAppearance({
      themes: {
        light: { background: "#ffffff", foreground: "#eeeeee" },
        dark: { background: "#000000", foreground: "#111111" },
      },
    });

    expect(appearance.themes.light.foreground).toBe("#000000");
    expect(appearance.themes.dark.foreground).toBe("#ffffff");
  });

  test("falls back to the readable endpoint when a color is too close to the background", () => {
    expect(readableColor("#eeeeee", "#ffffff", "#000000")).toBe("#000000");
    expect(readableColor("#111111", "#000000", "#ffffff")).toBe("#ffffff");
  });
});
