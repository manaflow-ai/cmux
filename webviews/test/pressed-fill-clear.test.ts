// The shared pressed role (--ds-color-pressed: ghost and subtle buttons held, open popups, dialog and
// bookmark buttons, onboarding) is a wash: the text over clear, pressedFill's 11% (light) and 14% (dark)
// in design-tokens.md section 1. It once fell back to the app theme's pressed token, an opaque surface
// step (theme/appTheme.ts: mix(bg, fg)), so every press painted a solid slab over host glass or a picture.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const desktop = fs.readFileSync(path.resolve(import.meta.dir, "../src/pages/shared/desktop.css"), "utf8");
const role = (name: string): string => {
  const match = desktop.match(new RegExp(`--ds-color-${name}:\\s*([^;]+);`));
  if (!match) throw new Error(`no --ds-color-${name}`);
  return match[1]!;
};

test("the pressed role never takes the app theme's opaque pressed surface", () => {
  expect(role("pressed")).not.toContain("--cmux-app-");
});

test("the pressed role is the text over clear, 11% light and 14% dark", () => {
  const value = role("pressed");
  expect(value).toContain("light-dark(");
  expect(value).toContain("CanvasText) 11%, transparent)");
  expect(value).toContain("CanvasText) 14%, transparent)");
});

test("hover, selection and pressed all end on a clear fallback", () => {
  for (const name of ["hover", "selection", "pressed"]) expect(role(name)).toMatch(/transparent\)+\s*$/);
});
