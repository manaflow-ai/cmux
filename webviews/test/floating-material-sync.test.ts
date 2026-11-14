// One floating material, web and native (Leo, 2026-11-11: "The point is, the styles mix and they
// don't look good. So they need to look good."). schemas/design-scale/design-scale.json is the one
// source: the page reads it through gen-design-scale (desktop.css), and Swift's GlassMenuMaterial
// carries the same numbers. This fails when the Swift side drifts from the JSON.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import designScale from "../../schemas/design-scale/design-scale.json";

const repo = (file: string) => readFileSync(new URL(`../../${file}`, import.meta.url), "utf8");
const swift = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/GlassMenu/GlassMenuMaterial.swift");
const menu = designScale.glass.find((level) => level.name === "menu") as { veil?: number; tint: number };
const named = (name: string) => designScale.namedRadii.find((radius) => radius.name === name) as { px: number };
const control = (name: string) => designScale.controls.find((row) => row.name === name) as { px: number };

const swiftNumber = (name: string) => {
  const match = swift.match(new RegExp(`static let ${name}: (?:Double|CGFloat) = ([\\d.]+)`));
  if (!match) throw new Error(`GlassMenuMaterial.${name} is not a number literal`);
  return Number(match[1]);
};

test("the native menu veil is the menu level's veil", () => {
  expect(menu.veil).toBeGreaterThan(0);
  expect(swift).toContain("veilPercent: Double = TransientMaterial.standard.hostVeil * 100");
  expect(designScale.transientMaterial.hostVeil * 100).toBe(menu.veil as number);
});

test("the native menu radius is the popup radius, and the native default outer radius is too", () => {
  expect(swiftNumber("defaultCornerRadius")).toBe(named("popup").px);
  const tunables = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Tunables/MetricTunables.swift");
  const pane = tunables.match(/"densityPaneCornerRadius"[\s\S]*?compact: ([\d.]+), comfortable: ([\d.]+)\)/);
  expect(pane?.slice(1).map(Number)).toEqual([named("popup").px, named("popup").px]);
});

test("the native menu row is the row control", () => {
  expect(swift).toContain("public static let rowHeight: CGFloat = DesignTokens.controlRow");
  const tokens = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/DesignTokens.swift");
  expect(tokens).toContain(`static let controlRow: CGFloat = ${control("row").px}`);
});

test("the native menu is the menu glass level", () => {
  expect(swift).toContain("static let level: GlassLevel = .menu");
});

test("the page lays the same veil on the App's glass", () => {
  const glass = repo("webviews/src/ui/glass/glass.css");
  expect(glass).toContain("var(--ds-glass-menu-veil, 40%)");
  expect(repo("webviews/src/pages/shared/desktop.css")).toContain(`--ds-glass-menu-veil: ${menu.veil}%;`);
});
