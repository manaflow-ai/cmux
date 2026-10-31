// The liquid glass lens's pure parts (src/ui/glass/glassState.ts; plans/cmux-next/glass-lens-DESIGN.md):
// the host's backdrop payload merge, the effective mode (plain under Reduce Transparency), and the
// lens geometry the shader mirrors.
import { describe, expect, test } from "bun:test";
import {
  BACKDROP_EVENT,
  EMPTY_BACKDROP,
  channelStrengths,
  installBackdropFallback,
  lensDisplacement,
  lensProfile,
  mergeBackdrop,
  powerOfTwo,
  readBackdrop,
  resolveGlassMode,
  rimBand,
  roundedRectSdf,
} from "../src/ui/glass/glassState";

describe("mergeBackdrop", () => {
  const first = mergeBackdrop(EMPTY_BACKDROP, {
    image: "data:image/jpeg;base64,AAA",
    key: "art-1",
    rect: { x: 0, y: -10, width: 800, height: 600 },
    blur: 12,
    tint: "rgba(0, 0, 0, 0.3)",
  });

  test("takes every field of a full payload", () => {
    expect(first).toEqual({
      image: "data:image/jpeg;base64,AAA",
      key: "art-1",
      rect: { x: 0, y: -10, width: 800, height: 600 },
      blur: 12,
      tint: "rgba(0, 0, 0, 0.3)",
    });
  });

  test("a partial payload keeps the rest, and the image is only sent when its key changes", () => {
    const moved = mergeBackdrop(first, { rect: { x: 20, y: 0, width: 400, height: 300 } });
    expect(moved.image).toBe(first.image);
    expect(moved.key).toBe("art-1");
    expect(moved.rect).toEqual({ x: 20, y: 0, width: 400, height: 300 });
  });

  test("a null image clears it (a moving wallpaper, Clear Glass)", () => {
    expect(mergeBackdrop(first, { image: null, key: "none" }).image).toBeNull();
  });

  test("malformed fields are ignored", () => {
    const merged = mergeBackdrop(first, { rect: { x: 0, y: 0, width: -1, height: 2 }, blur: Number.NaN, tint: "" });
    expect(merged).toEqual(first);
    expect(mergeBackdrop(first, null)).toBe(first);
    expect(mergeBackdrop(first, "nope")).toBe(first);
  });
});

describe("resolveGlassMode", () => {
  test("the host's mode, plain by default (the lens is opt-in)", () => {
    expect(resolveGlassMode(null, false)).toBe("plain");
    expect(resolveGlassMode("lens", false)).toBe("lens");
    expect(resolveGlassMode("spectrum", false)).toBe("spectrum");
    expect(resolveGlassMode("plain", false)).toBe("plain");
    expect(resolveGlassMode("bogus", false)).toBe("plain");
  });

  test("Reduce Transparency is always plain", () => {
    for (const attribute of [null, "lens", "spectrum", "plain"])
      expect(resolveGlassMode(attribute, true)).toBe("plain");
  });
});

describe("lens geometry", () => {
  test("the profile bends most at the rim and not at all past the band", () => {
    expect(lensProfile(0)).toBe(1);
    expect(lensProfile(1)).toBe(0);
    expect(lensProfile(2)).toBe(0);
    let previous = 1;
    for (let t = 0.05; t <= 1; t += 0.05) {
      const value = lensProfile(t);
      expect(value).toBeLessThanOrEqual(previous);
      previous = value;
    }
    // Steep at the edge (a circle's cross-section), flat where it meets the center.
    expect(lensProfile(0) - lensProfile(0.1)).toBeGreaterThan(lensProfile(0.9) - lensProfile(1) + 0.3);
  });

  test("the rounded rect SDF", () => {
    expect(roundedRectSdf(0, 0, 50, 20, 8)).toBe(-20);
    expect(roundedRectSdf(50, 0, 50, 20, 8)).toBeCloseTo(0);
    expect(roundedRectSdf(60, 0, 50, 20, 8)).toBeCloseTo(10);
    // The corner is round: the box's corner point is outside by the radius's sqrt(2) - 1.
    expect(roundedRectSdf(50, 20, 50, 20, 8)).toBeCloseTo(8 * Math.SQRT2 - 8);
    // A circle (radius at half size).
    expect(roundedRectSdf(30, 0, 30, 30, 30)).toBeCloseTo(0);
    expect(roundedRectSdf(0, 0, 30, 30, 999)).toBeCloseTo(-30);
  });

  test("the displacement is the refraction at the rim and zero outside or deep inside", () => {
    const band = rimBand(18, 120, 60);
    expect(band).toBe(54);
    expect(lensDisplacement(0, 18, band)).toBe(0);
    expect(lensDisplacement(5, 18, band)).toBe(0);
    expect(lensDisplacement(-0.0001, 18, band)).toBeCloseTo(18, 0);
    expect(lensDisplacement(-band, 18, band)).toBe(0);
    expect(rimBand(18, 10, 30)).toBe(10);
  });

  test("Spectrum splits the channels; lens and plain do not", () => {
    expect(channelStrengths("lens", 0.35)).toEqual([1, 1, 1]);
    expect(channelStrengths("plain", 0.35)).toEqual([1, 1, 1]);
    expect(channelStrengths("spectrum", 0.25)).toEqual([1, 1.25, 1.5]);
  });

  test("power-of-two texture sizes", () => {
    expect(powerOfTwo(1)).toBe(1);
    expect(powerOfTwo(600)).toBe(1024);
    expect(powerOfTwo(512)).toBe(512);
    expect(powerOfTwo(5000)).toBe(1024);
  });
});

describe("the cmuxTheme.backdrop fallback", () => {
  test("merges into cmuxBackdropState and dispatches cmux-backdrop", () => {
    const view = new EventTarget() as unknown as Window & { cmuxTheme?: Record<string, unknown> };
    installBackdropFallback(view);
    const seen: unknown[] = [];
    view.addEventListener(BACKDROP_EVENT, (event) => seen.push((event as CustomEvent).detail));
    const backdrop = (view.cmuxTheme as { backdrop(partial: unknown): void }).backdrop;
    backdrop({ image: "data:image/png;base64,AA", key: "k", rect: { x: 0, y: 0, width: 10, height: 10 } });
    backdrop({ blur: 4 });
    expect(seen).toHaveLength(2);
    expect(readBackdrop(view)).toEqual({
      image: "data:image/png;base64,AA",
      key: "k",
      rect: { x: 0, y: 0, width: 10, height: 10 },
      blur: 4,
      tint: "transparent",
    });
  });

  test("never replaces the host's backdrop", () => {
    const host = () => undefined;
    const view = new EventTarget() as unknown as Window & { cmuxTheme?: Record<string, unknown> };
    view.cmuxTheme = { apply: () => undefined, backdrop: host };
    installBackdropFallback(view);
    expect(view.cmuxTheme.backdrop).toBe(host);
    expect(typeof view.cmuxTheme.apply).toBe("function");
  });
});
