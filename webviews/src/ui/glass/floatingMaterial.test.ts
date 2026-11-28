import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { rawBlursInCss } from "../../../scripts/check-glass-levels";
import { experimentById } from "../../experiments/registry";
import { floatingMaterial } from "./floatingMaterial.experiment";

// RFD 0207 "Floating material to B1": the floating levels on B1's one material (88%, blur 32, saturate 1)
// behind the floating-material experiment, off by default.
const desktopCss = readFileSync(join(import.meta.dir, "../../pages/shared/desktop.css"), "utf8");
const block = desktopCss.slice(desktopCss.indexOf("/* FLOATING MATERIAL B1"));
const rule = block.slice(block.indexOf('  :root[data-floating-material="b1"]'), block.indexOf("\n  }\n") + 4);

test("the experiment ships today's levels and is registered", () => {
  expect(floatingMaterial.defaultArm).toBe("levels");
  expect(experimentById("floating-material")).toBe(floatingMaterial);
});

test("under b1 every floating level is 88%, blur 32 (the menu level's radius), saturate 1", () => {
  for (const level of ["popover", "menu", "chip"]) {
    expect(rule).toContain(`--ds-glass-${level}-tint: 88%;`);
    expect(rule).toContain(`--ds-glass-${level}-blur: blur(var(--ds-glass-menu-radius)) saturate(1);`);
  }
  expect(rule).toContain("--ds-transient-web-tint: 88%;");
  expect(rule).toContain("--ds-transient-web-saturation: 1;");
  expect(desktopCss).toContain("--ds-glass-menu-radius: 32px;");
  expect(rule).not.toContain("chrome");
});

test("the block never applies under Reduce Transparency or Liquid Glass off, and adds no raw blur", () => {
  expect(block).toContain("@media not (prefers-reduced-transparency: reduce) {");
  expect(rule).toContain(':root[data-floating-material="b1"]:not([data-reduce-transparency], [data-glass="off"])');
  expect(rawBlursInCss(desktopCss, "desktop.css")).toEqual([]);
});
