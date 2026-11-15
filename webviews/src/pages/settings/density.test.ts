// Densities on the Settings page (plans/cmux-next/density-DESIGN.md): the previews draw with the
// app's token math (Swift DensityTokensTests pins the same numbers), Compact is today's, and a
// custom density round-trips through its cmux.json and export form.
import { expect, test } from "bun:test";
import { customDensities, duplicate, parseExport, PRESETS, resolve, toJSON, uniqueID } from "./density";
import { isCustomDensity } from "./validate";

// Lawrence 2026-11-13: Compact is 20 px tall everywhere, Default is Helium, Comfortable is Chrome's text.
test("Compact draws 20 px rows and Comfortable its own", () => {
  const compact = resolve(PRESETS[1]!);
  expect(compact).toEqual({
    sidebarRowHeight: 20,
    tabHeight: 20,
    tabStripHeight: 26,
    itemCornerRadius: 5,
    iconSize: 14,
    body: 12,
    caption: 10.5,
    inset: 6,
  });
  expect(resolve(PRESETS[3]!).sidebarRowHeight).toBe(34);
  expect(resolve(PRESETS[3]!).body).toBe(14);
});

// Lucas 2026-11-13: Ultra-compact and Compact share Compact's 20 px rows, Ultra-compact's text a step smaller;
// Default is the ChatGPT app's 14 px text, which Comfortable keeps; Spacious is bigger.
test("rows and text never shrink from Ultra-compact to Spacious (as the app's)", () => {
  expect(PRESETS.map((preset) => resolve(preset).sidebarRowHeight)).toEqual([20, 20, 30, 34, 42]);
  expect(PRESETS.map((preset) => resolve(preset).body)).toEqual([11, 12, 14, 14, 16]);
});

test("every density's icons sit on the icon scale (as the app's)", () => {
  // Leo 2026-11-04: "ofc we'll want to be doing proportion/scales per compact/comfortable/whatever ui scaling modes too"
  expect(PRESETS.map((preset) => resolve(preset).iconSize)).toEqual([12, 14, 16, 20, 24]);
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
  expect(PRESETS.map((preset) => resolve(preset).tabHeight)).toEqual([20, 20, 30, 34, 42]);
  expect(PRESETS.map((preset) => resolve(preset).tabStripHeight)).toEqual([26, 26, 36, 40, 50]);
  // A copy of a built-in keeps following its rows: no preset pins its tab height.
  expect(PRESETS.some((preset) => preset.tokens?.tabHeight !== undefined)).toBe(false);
});

test("Default is the Codex-size middle density, and sizes grow in order", () => {
  expect(PRESETS.map((preset) => preset.id)).toEqual(["ultraCompact", "compact", "cozy", "comfortable", "spacious"]);
  const sizes = PRESETS.map((preset) => resolve(preset));
  expect(sizes[2]!.body).toBe(14);
  expect(sizes[2]!.sidebarRowHeight).toBe(30);
  expect(sizes[2]).toMatchObject({ tabHeight: 30, tabStripHeight: 36, itemCornerRadius: 8 });
  expect(sizes[1]).toMatchObject({ body: 12, sidebarRowHeight: 20 });
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
    fontSize: 14,
    tokens: { sidebarRowHeight: 30, tabStripHeight: 36 },
    basedOn: "cozy",
  });
  expect(uniqueID("Compact", [])).toBe("compact-2");
  expect(uniqueID("日本", [])).toBe("custom");
});
