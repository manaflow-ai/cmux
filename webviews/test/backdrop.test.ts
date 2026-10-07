import { expect, test } from "bun:test";
import { compositeOpaque, parseComputedColor, solidBackdropColor } from "../src/backdrop";

test("computed colors parse in the rgb, rgba and color(srgb) forms", () => {
  expect(parseComputedColor("rgb(30, 30, 46)")).toEqual({ r: 30, g: 30, b: 46, a: 1 });
  expect(parseComputedColor("rgba(30, 30, 46, 0)")).toEqual({ r: 30, g: 30, b: 46, a: 0 });
  expect(parseComputedColor("rgb(30 30 46 / 50%)")).toEqual({ r: 30, g: 30, b: 46, a: 0.5 });
  expect(parseComputedColor("color(srgb 1 0 0 / 0.25)")).toEqual({ r: 255, g: 0, b: 0, a: 0.25 });
  expect(parseComputedColor("transparent")?.a).toBe(0);
  expect(parseComputedColor("hsl(1 2% 3%)")).toBeNull();
});

test("the solid color is the backdrop painted over the theme color at full alpha", () => {
  const theme = { r: 30, g: 30, b: 46, a: 1 };
  // See-through window: the backdrop is clear, so the bars take the theme color.
  expect(compositeOpaque({ r: 30, g: 30, b: 46, a: 0 }, theme)).toBe("rgb(30, 30, 46)");
  // Opaque window: the backdrop itself.
  expect(compositeOpaque(theme, { r: 0, g: 0, b: 0, a: 1 })).toBe("rgb(30, 30, 46)");
  // R55 override at half alpha: half way between the override and the theme.
  expect(compositeOpaque({ r: 230, g: 30, b: 46, a: 0.5 }, theme)).toBe("rgb(130, 30, 46)");
});

test("the theme color is the surface token without its opacity, else the terminal theme background", () => {
  const clear = { r: 0, g: 0, b: 0, a: 0 };
  expect(solidBackdropColor(clear, { r: 30, g: 30, b: 46, a: 0.6 }, { r: 1, g: 1, b: 1, a: 1 })).toBe(
    "rgb(30, 30, 46)",
  );
  expect(solidBackdropColor(clear, null, { r: 255, g: 255, b: 255, a: 1 })).toBe("rgb(255, 255, 255)");
  expect(solidBackdropColor({ r: 200, g: 0, b: 0, a: 0.5 }, { r: 0, g: 0, b: 200, a: 0.6 }, null)).toBe(
    "rgb(100, 0, 100)",
  );
  expect(solidBackdropColor(null, null, null)).toBeNull();
});
