// Densities on the Settings page (plans/cmux-next/density-DESIGN.md): the previews draw with the
// app's token math (Swift DensityTokensTests pins the same numbers), Compact is today's, and a
// custom density round-trips through its cmux.json and export form.
import { expect, test } from "bun:test";
import { customDensities, duplicate, parseExport, PRESETS, resolve, toJSON, uniqueID } from "./density";
import { isCustomDensity } from "./validate";

// Lucas 2026-11-16: every density is Default times one factor (0.8, 0.9, 1, 1.1, 1.2), with 24, 28, 30, 32
// and 36 pt rows (Swift `DensityPreset`). Compact is Helium's.
test("Compact draws Helium's 28 pt rows at Default's proportions", () => {
  const compact = resolve(PRESETS[1]!);
  expect(compact).toEqual({
    sidebarRowHeight: 28,
    tabHeight: 28,
    tabStripHeight: 33,
    itemCornerRadius: 7,
    iconSize: 14,
    body: 12.6,
    caption: 11,
    inset: 5.5,
  });
  expect(PRESETS[1]).toMatchObject({ level: 0.15, spacing: 0.9, fontSize: 12.6 });
});

test("rows and text scale with one factor from Ultra-compact to Spacious (as the app's)", () => {
  expect(PRESETS.map((preset) => resolve(preset).sidebarRowHeight)).toEqual([24, 28, 30, 32, 36]);
  expect(PRESETS.map((preset) => resolve(preset).body)).toEqual([11.2, 12.6, 14, 15.4, 16.8]);
  expect(PRESETS.map((preset) => preset.spacing)).toEqual([0.8, 0.9, 1, 1.1, 1.2]);
});

test("every density's icons sit on the icon scale (as the app's)", () => {
  // Leo 2026-11-04: "ofc we'll want to be doing proportion/scales per compact/comfortable/whatever ui scaling modes too"
  expect(PRESETS.map((preset) => resolve(preset).iconSize)).toEqual([14, 14, 16, 16, 16]);
  expect(resolve({ id: "x", name: "X", level: 0.5, tokens: { iconSize: 15 } }).iconSize).toBe(15);
});

test("a custom font size and exact tokens win", () => {
  const sizes = resolve({ id: "big", name: "Big", level: 0, fontSize: 15, tokens: { sidebarRowHeight: 22 } });
  expect(sizes.body).toBe(15);
  expect(sizes.sidebarRowHeight).toBe(22);
  // Tabs follow the row (Swift `Metrics.tabHeight`).
  expect(sizes.tabHeight).toBe(22);
});

test("a custom density round-trips and passes the settings check", () => {
  const tight = {
    id: "my-tight",
    name: "My Tight",
    basedOn: "compact",
    level: -0.25,
    spacing: 0.9,
    fontSize: 11.5,
    tokens: { sidebarRowHeight: 22 },
  };
  const json = toJSON(tight);
  expect(isCustomDensity(json)).toBe(true);
  expect(customDensities([json])).toEqual([tight]);
  const imported = parseExport(JSON.stringify(json), [tight]);
  expect(imported?.id).toBe("my-tight-2");
  expect(imported?.fontSize).toBe(11.5);
  expect(parseExport("not json", [])).toBeNull();
  expect(isCustomDensity({ id: "Bad Id", name: "x" })).toBe(false);
});

// Austin 2026-11-05: five densities in this order, Default (id cozy) in the middle; Lucas 2026-11-13: its
// rows are 30 pt and its text the ChatGPT app's 14 pt; Comfortable and Spacious above it.
// The previews draw what the app draws (Swift TabsFollowRowsTests): tabs as tall as the rows, and a strip that
// grows with them.
test("every preset's tabs and strip are the app's", () => {
  expect(PRESETS.map((preset) => resolve(preset).tabHeight)).toEqual([24, 28, 30, 32, 36]);
  expect(PRESETS.map((preset) => resolve(preset).tabStripHeight)).toEqual([29, 33, 36, 39, 43]);
  // A copy of a built-in keeps following its rows: no preset pins its tab height.
  expect(PRESETS.some((preset) => preset.tokens?.tabHeight !== undefined)).toBe(false);
});

test("Default is the Codex-size middle density, and sizes grow in order", () => {
  expect(PRESETS.map((preset) => preset.id)).toEqual(["ultraCompact", "compact", "cozy", "comfortable", "spacious"]);
  const sizes = PRESETS.map((preset) => resolve(preset));
  expect(sizes[2]!.body).toBe(14);
  expect(sizes[2]!.sidebarRowHeight).toBe(30);
  expect(sizes[2]).toMatchObject({ tabHeight: 30, tabStripHeight: 36, itemCornerRadius: 8 });
  expect(sizes[1]).toMatchObject({ body: 12.6, sidebarRowHeight: 28 });
  for (let index = 1; index < sizes.length; index += 1) {
    expect(sizes[index]!.body).toBeGreaterThanOrEqual(sizes[index - 1]!.body);
    expect(sizes[index]!.sidebarRowHeight).toBeGreaterThanOrEqual(sizes[index - 1]!.sidebarRowHeight);
  }
  expect(sizes[0]!.body).toBeLessThan(sizes[1]!.body);
  expect(sizes[4]!.body).toBeGreaterThan(sizes[3]!.body);
});

test("duplicate makes a unique id and remembers its built-in", () => {
  const copy = duplicate(PRESETS[2]!, "Default Copy", []);
  expect(copy).toEqual({
    id: "default-copy",
    name: "Default Copy",
    level: 0.5,
    spacing: 1,
    fontSize: 14,
    tokens: { sidebarRowHeight: 30, tabStripHeight: 36 },
    basedOn: "cozy",
  });
  expect(uniqueID("Compact", [])).toBe("compact-2");
  expect(uniqueID("日本", [])).toBe("custom");
});
