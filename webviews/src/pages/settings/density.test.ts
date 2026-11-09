// Densities on the Settings page (plans/cmux-next/density-DESIGN.md): the previews draw with the
// app's token math (Swift DensityTokensTests pins the same numbers), Compact is today's, and a
// custom density round-trips through its cmux.json and export form.
import { expect, test } from "bun:test";
import { customDensities, duplicate, parseExport, PRESETS, resolve, toJSON, uniqueID } from "./density";
import { isCustomDensity } from "./validate";

test("Compact draws today's sizes and Comfortable its own", () => {
  const compact = resolve(PRESETS[1]!);
  expect(compact).toEqual({
    sidebarRowHeight: 24,
    tabHeight: 24,
    tabStripHeight: 28,
    itemCornerRadius: 6,
    iconSize: 14,
    body: 12,
    caption: 10.5,
    inset: 6,
  });
  expect(resolve(PRESETS[3]!).sidebarRowHeight).toBe(34);
  expect(resolve(PRESETS[3]!).body).toBe(13.5);
});

test("rows and text grow from Ultra-compact to Spacious (as the app's)", () => {
  expect(PRESETS.map((preset) => resolve(preset).sidebarRowHeight)).toEqual([20, 24, 28, 34, 42]);
  expect(PRESETS.map((preset) => resolve(preset).body)).toEqual([11.5, 12, 13, 13.5, 14.5]);
});

test("every density's icons sit on the icon scale (as the app's)", () => {
  // Leo 2026-11-04: "ofc we'll want to be doing proportion/scales per compact/comfortable/whatever ui scaling modes too"
  expect(PRESETS.map((preset) => resolve(preset).iconSize)).toEqual([12, 14, 16, 16, 20]);
  expect(resolve({ id: "x", name: "X", level: 0.5, tokens: { iconSize: 15 } }).iconSize).toBe(15);
});

test("a custom font size and exact tokens win", () => {
  const sizes = resolve({ id: "big", name: "Big", level: 0, fontSize: 15, tokens: { sidebarRowHeight: 22 } });
  expect(sizes.body).toBe(15);
  expect(sizes.sidebarRowHeight).toBe(22);
  expect(sizes.tabHeight).toBe(24);
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

// Austin 2026-11-05: five densities in this order, Default (id cozy) in the middle with the
// ChatGPT and Codex desktop apps' 13 pt text and 28 pt rows; Comfortable and Spacious above it.
test("Default is the Codex-size middle density, and sizes grow in order", () => {
  expect(PRESETS.map((preset) => preset.id)).toEqual(["ultraCompact", "compact", "cozy", "comfortable", "spacious"]);
  const sizes = PRESETS.map((preset) => resolve(preset));
  expect(sizes[2]!.body).toBe(13);
  expect(sizes[2]!.sidebarRowHeight).toBe(28);
  expect(sizes[1]).toMatchObject({ body: 12, sidebarRowHeight: 24 });
  for (let index = 1; index < sizes.length; index += 1) {
    expect(sizes[index]!.body).toBeGreaterThan(sizes[index - 1]!.body);
    expect(sizes[index]!.sidebarRowHeight).toBeGreaterThan(sizes[index - 1]!.sidebarRowHeight);
  }
});

test("duplicate makes a unique id and remembers its built-in", () => {
  const copy = duplicate(PRESETS[2]!, "Default Copy", []);
  expect(copy).toEqual({ id: "default-copy", name: "Default Copy", level: 0.5, fontSize: 13, basedOn: "cozy" });
  expect(uniqueID("Compact", [])).toBe("compact-2");
  expect(uniqueID("日本", [])).toBe("custom");
});
