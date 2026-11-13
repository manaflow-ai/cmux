// The composer's trailing glyphs (Send's ↵, Stop, the mic) draw at the composer's one glyph size, as
// +, the mode's shield and the provider mark do (Austin 2026-11-11: standardize icon sizes, the mic a
// bit too big), on the density (16 px at Default), with Claude Code desktop's 1.5 px line (Leo
// 2026-11-02), through the shared tokens on the composer's root, in both looks and on New Tab; and ↵
// is drawn in Claude Code's proportions. The 18 px glyph (2026-11-02 to 11-11) stood out over +.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { RETURN_GLYPH_PATH } from "../src/agent-session/acpmux/composerPickerModel";

const acpmux = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
const css = (file: string) => readFileSync(path.join(acpmux, file), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const block = (source: string, selector: string) => {
  const at = source.indexOf(selector);
  expect(at, `${selector} has a rule`).toBeGreaterThanOrEqual(0);
  return source.slice(source.indexOf("{", at) + 1, source.indexOf("}", at));
};
const token = (body: string, name: string) => body.match(new RegExp(`${name}:\\s*([^;]+);`))?.[1]?.trim();

describe("composer trailing glyphs", () => {
  test("the composer root declares one 16 px glyph on the density and a 1.5 px line", () => {
    const root = block(css("composerLocation.css"), ".acpmux-dock,\n:is(.acpmux-composer, .nt-composer) {");
    expect(token(root, "--acpmux-composer-glyph")).toBe("calc(16px * var(--acpmux-density))");
    expect(token(root, "--acpmux-composer-trail-glyph")).toBe("var(--acpmux-composer-glyph)");
    expect(Number(token(root, "--acpmux-composer-trail-stroke"))).toBeCloseTo(1.5, 1);
    const newTab = block(css("newtab/screen.css"), ".nt-screen .nt-composer {\n  --acpmux-composer-control");
    expect(token(newTab, "--acpmux-composer-glyph")).toMatch(/^calc\(16px \* var\(--cmux-density-scale/);
    expect(token(newTab, "--acpmux-composer-trail-glyph")).toBe("var(--acpmux-composer-glyph)");
    expect(token(newTab, "--acpmux-composer-trail-stroke")).toBe(token(root, "--acpmux-composer-trail-stroke"));
  });

  test("Send, Stop and the mic take the tokens in the chat (both looks) and on New Tab", () => {
    for (const [file, selector] of [
      ["composerLocation.css", ":is(.acpmux-composer, .nt-composer) :is(.acpmux-send, .acpmux-mic) > .acpmux-icon"],
      ["newtab/screen.css", ".nt-pickers :is(.acpmux-send, .acpmux-mic) .acpmux-icon"],
    ] as const) {
      const body = block(css(file), selector);
      expect(body).toContain("width: var(--acpmux-composer-trail-glyph");
      expect(body).toContain("height: var(--acpmux-composer-trail-glyph");
      expect(body).toContain("stroke-width: var(--acpmux-composer-trail-stroke");
    }
    // + takes the same one glyph.
    const plus = block(
      css("composerLocation.css"),
      ":is(.acpmux-composer, .nt-composer) .acpmux-composer-plus .acpmux-picker-button .acpmux-icon,",
    );
    expect(plus).toContain("width: var(--acpmux-composer-glyph)");
    expect(css("composerLocation.css")).not.toMatch(/\.acpmux-composer-bar \.acpmux-mic \.acpmux-icon\s*\{/);
  });

  test("↵ is drawn in Claude Code's proportions", () => {
    const nums = RETURN_GLYPH_PATH.match(/-?\d*\.?\d+/g)!.map(Number);
    // Absolute points: the stem's top, the bar's left end, the arrowhead's two tips.
    const [stemX, stemTop] = nums;
    const barLeft = Number(RETURN_GLYPH_PATH.match(/H(-?\d*\.?\d+)/)![1]);
    const head = RETURN_GLYPH_PATH.match(
      /M(\d*\.?\d+) (\d*\.?\d+) (\d*\.?\d+) (\d*\.?\d+)l(-?\d*\.?\d+) (-?\d*\.?\d+)/,
    )!;
    const [, tipX, tipTop, , barY, , down] = head.map(Number);
    const width = stemX! - barLeft;
    expect(width).toBeGreaterThanOrEqual(10); // base: 9.2
    expect(barY - tipTop).toBeGreaterThanOrEqual(3.6); // the arrowhead's half height, base 3.1
    expect(down).toBeCloseTo(barY - tipTop, 1); // symmetric head
    expect(tipX).toBeGreaterThan(barLeft);
    // The ink centers in the 16 grid (within half a unit), so the glyph centers in its button.
    const top = stemTop!;
    const bottom = barY + down;
    expect(Math.abs((top + bottom) / 2 - 8)).toBeLessThan(0.5);
    expect(Math.abs((barLeft + stemX!) / 2 - 8)).toBeLessThan(0.5);
  });
});
