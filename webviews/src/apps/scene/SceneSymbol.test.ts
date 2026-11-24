import { describe, expect, test } from "bun:test";
import { bundledIconPack, MISSING_ICON } from "../../agent-session/acpmux/icons/iconPack";
import { SCENE_FALLBACK_ICON, SCENE_SF_SYMBOLS, appSceneIcon, appSceneIconFilled } from "./SceneSymbol";

// Leo, 2026-11-16: "I still haven't seen a good weather/time/calendar thing, like apple's iOS or desktop
// widgets". The AppKit sidebar draws these as real SF Symbols; the web scene renderer must draw a pack
// glyph that means the same thing, not the neutral fallback.
const WIDGET_SYMBOLS = [
  // weather
  "sun.max",
  "sun.max.fill",
  "moon",
  "moon.fill",
  "moon.stars",
  "moon.stars.fill",
  "cloud",
  "cloud.fill",
  "cloud.sun",
  "cloud.sun.fill",
  "cloud.moon",
  "cloud.moon.fill",
  "cloud.rain",
  "cloud.rain.fill",
  "cloud.sun.rain",
  "cloud.sun.rain.fill",
  "cloud.moon.rain",
  "cloud.moon.rain.fill",
  "cloud.heavyrain",
  "cloud.heavyrain.fill",
  "cloud.drizzle",
  "cloud.drizzle.fill",
  "cloud.snow",
  "cloud.snow.fill",
  "cloud.sleet",
  "cloud.sleet.fill",
  "cloud.bolt",
  "cloud.bolt.fill",
  "cloud.bolt.rain",
  "cloud.bolt.rain.fill",
  "cloud.fog",
  "cloud.fog.fill",
  "wind",
  "snowflake",
  "thermometer",
  "thermometer.medium",
  "humidity",
  "humidity.fill",
  "umbrella",
  "umbrella.fill",
  "sunrise",
  "sunrise.fill",
  "sunset",
  "sunset.fill",
  // time and calendar
  "calendar",
  "calendar.badge.clock",
  "clock",
  "clock.fill",
  "alarm",
  "alarm.fill",
  "location",
  "location.fill",
  // todo and common controls
  "checkmark.circle",
  "checkmark.circle.fill",
  "circle",
  "circle.fill",
  "largecircle.fill.circle",
  "plus.circle",
  "plus.circle.fill",
  "checklist",
  "chevron.right",
  "chevron.down",
  "plus",
  "minus",
  "xmark",
  "star",
  "star.fill",
  "heart",
  "heart.fill",
  "bell",
  "bell.fill",
  "flag",
  "flag.fill",
  "list.bullet",
  "square",
  "checkmark.square",
  "checkmark.square.fill",
];

describe("scene SF symbols", () => {
  for (const name of WIDGET_SYMBOLS) {
    test(`${name} draws a real pack glyph`, () => {
      const icon = appSceneIcon(name);
      expect(icon).not.toBe(SCENE_FALLBACK_ICON);
      expect(icon).not.toBe(MISSING_ICON);
      expect(Object.hasOwn(bundledIconPack.icons, icon)).toBe(true);
    });
  }

  test("every mapped SF name points at a glyph the pack has", () => {
    const dangling = Object.entries(SCENE_SF_SYMBOLS).filter(([, icon]) => !Object.hasOwn(bundledIconPack.icons, icon));
    expect(dangling).toEqual([]);
  });

  test("weather conditions draw distinct glyphs", () => {
    const conditions = [
      "sun.max",
      "moon.stars",
      "cloud",
      "cloud.sun",
      "cloud.moon",
      "cloud.rain",
      "cloud.heavyrain",
      "cloud.drizzle",
      "cloud.snow",
      "cloud.sleet",
      "cloud.bolt",
      "cloud.bolt.rain",
      "cloud.fog",
      "wind",
      "snowflake",
    ];
    expect(new Set(conditions.map(appSceneIcon)).size).toBe(conditions.length);
  });

  test("a .fill name draws Solid and an outline name draws Line", () => {
    expect(appSceneIconFilled("cloud.rain.fill")).toBe(true);
    expect(appSceneIconFilled("largecircle.fill.circle")).toBe(true);
    expect(appSceneIconFilled("cloud.rain")).toBe(false);
    // Already filled in Line; its Solid form is a selected swatch's ring.
    expect(appSceneIconFilled("circle.fill")).toBe(false);
    // The fallback dot never draws its Solid ring.
    expect(appSceneIconFilled("sunflower.fill")).toBe(false);
  });

  // An unmapped name (a symbol this table lacks) draws a quiet dot, never the pack's "?" box.
  test("an unknown name draws the neutral dot, not the missing-icon box", () => {
    expect(SCENE_FALLBACK_ICON).not.toBe(MISSING_ICON);
    expect(Object.hasOwn(bundledIconPack.icons, SCENE_FALLBACK_ICON)).toBe(true);
    expect(appSceneIcon("not.a.real.sf.symbol")).toBe(SCENE_FALLBACK_ICON);
    expect(appSceneIcon("")).toBe(SCENE_FALLBACK_ICON);
  });
});
