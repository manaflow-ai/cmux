// The glass engine's optics (ui/glass/engine/optics.ts), which its layer shader computes per pixel:
// the bevel bends only near the rim, more for a thicker slab and a higher index, never outward, and
// a look out of range is clamped to what the shader takes.
import { expect, test } from "bun:test";
import {
  bendAt,
  bevelHeight,
  bevelSlope,
  frostLevel,
  GLASS_PRESETS,
  layerReach,
  resolveLook,
  roundedRectDistance,
} from "../src/ui/glass/engine/optics";
import { LAYER_FRAGMENT, PYRAMID_LEVELS } from "../src/ui/glass/engine/shaders";

test("the bevel rises from the edge to a flat center", () => {
  expect(bevelHeight(0)).toBe(0);
  expect(bevelHeight(1)).toBe(1);
  for (let t = 0.05; t < 1; t += 0.05) expect(bevelHeight(t)).toBeGreaterThan(bevelHeight(t - 0.05));
  expect(bevelSlope(0.01)).toBeGreaterThan(bevelSlope(0.5));
  expect(bevelSlope(1)).toBe(0);
});

test("the bend pulls inward at the rim and fades to nothing at the flat center", () => {
  const near = bendAt(0.1, 18, 22, 1.5);
  const mid = bendAt(0.5, 18, 22, 1.5);
  expect(near).toBeGreaterThan(0);
  expect(mid).toBeGreaterThan(0);
  expect(bendAt(1, 18, 22, 1.5)).toBe(0);
  expect(bendAt(0.98, 18, 22, 1.5)).toBeLessThan(0.05);
  for (let t = 0; t <= 1; t += 0.02) expect(bendAt(t, 18, 22, 1.5)).toBeGreaterThanOrEqual(0);
});

test("a thicker slab and a higher index bend more; index 1 or no bevel does not bend", () => {
  expect(bendAt(0.3, 18, 40, 1.5)).toBeGreaterThan(bendAt(0.3, 18, 22, 1.5));
  expect(bendAt(0.3, 18, 22, 1.8)).toBeGreaterThan(bendAt(0.3, 18, 22, 1.5));
  expect(bendAt(0.3, 18, 22, 1)).toBe(0);
  expect(bendAt(0.3, 0, 22, 1.5)).toBe(0);
  expect(bendAt(0.3, 18, 0, 1.5)).toBe(0);
});

test("the bend stays within the slab's reach", () => {
  for (const look of Object.values(GLASS_PRESETS))
    for (let t = 0; t <= 1; t += 0.01)
      expect(bendAt(t, look.bevel, look.thickness, look.ior)).toBeLessThanOrEqual(layerReach(look));
});

test("the shape's distance is a rounded rect for corner 2 and squarer for more", () => {
  expect(roundedRectDistance(0, 0, 50, 20, 10, 2)).toBe(-20);
  expect(roundedRectDistance(50, 0, 50, 20, 10, 2)).toBe(0);
  // The corner's diagonal point of a circular corner sits on the arc.
  const c = 40 + 10 * Math.SQRT1_2;
  const d = 10 + 10 * Math.SQRT1_2;
  expect(Math.abs(roundedRectDistance(c, d, 50, 20, 10, 2))).toBeLessThan(1e-9);
  // A squircle corner reaches further toward the box's corner than a circle.
  expect(roundedRectDistance(c, d, 50, 20, 10, 4)).toBeLessThan(0);
});

test("a look is clamped to what the shader takes", () => {
  const look = resolveLook({
    ior: 9,
    frost: -3,
    corner: 1,
    dispersion: 4,
    tint: [2, -1, 0.5, 0.3],
    radius: Number.NaN,
  });
  expect(look.ior).toBe(2);
  expect(look.frost).toBe(0);
  expect(look.corner).toBe(2);
  expect(look.dispersion).toBe(1);
  expect(look.tint).toEqual([1, 0, 0.5, 0.3]);
  expect(look.radius).toBe(GLASS_PRESETS.regular.radius);
});

test("frost reads a pyramid level that grows with the sigma and stops at the top", () => {
  expect(frostLevel(0, PYRAMID_LEVELS)).toBe(0);
  expect(frostLevel(2.5, PYRAMID_LEVELS)).toBeCloseTo(1, 5);
  expect(frostLevel(10, PYRAMID_LEVELS)).toBeCloseTo(3, 5);
  expect(frostLevel(1000, PYRAMID_LEVELS)).toBe(PYRAMID_LEVELS);
});

test("the layer shader computes the same bevel the optics module tests", () => {
  expect(LAYER_FRAGMENT).toContain("pow(1.0 - u * u * u * u, 0.25)");
  expect(LAYER_FRAGMENT).toContain("pow(1.0 - u * u * u * u, -0.75) * u * u * u");
  expect(LAYER_FRAGMENT).toContain("refract(vec3(0.0, 0.0, -1.0), n, 1.0 / ior)");
  expect(LAYER_FRAGMENT).not.toContain("${");
});
