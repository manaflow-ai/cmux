// The design scale is the one token source (schemas/design-scale, webviews/scripts/pages/gen-design-scale.mjs):
// desktop.css defines the variables and ui/theme.generated.css points Tailwind's theme at them, so
// `p-3`, `rounded-md`, `text-body` or `bg-hover` resolve to our tokens in every Tailwind entry, light
// and dark. This compiles the shared theme over a few classes and checks where each one points, and
// that every variable the theme names is defined by the generated block.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { compile } from "@tailwindcss/node";

const src = path.resolve(import.meta.dir, "../src");
const theme = fs.readFileSync(path.join(src, "ui/theme.generated.css"), "utf8");
const desktop = fs.readFileSync(path.join(src, "pages/shared/desktop.css"), "utf8");

async function build(classes: string[]): Promise<string> {
  const input = `@import "tailwindcss/theme.css" layer(theme);\n@import "tailwindcss/utilities.css" layer(utilities);\n${theme}`;
  const compiler = await compile(input, { base: src, onDependency: () => {} });
  return compiler.build(classes);
}

const rule = (css: string, selector: string): string => {
  const at = css.indexOf(`${selector} {`);
  if (at < 0) throw new Error(`no rule for ${selector}`);
  return css.slice(at, css.indexOf("}", at));
};

describe("Tailwind theme from the design scale", () => {
  test("utilities resolve to the generated tokens", async () => {
    const css = await build([
      "p-3",
      "rounded-md",
      "text-body",
      "bg-hover",
      "text-muted",
      "shadow-elevation-2",
      "duration-quick",
      "ease-standard",
    ]);
    // `@theme inline`: each utility carries the token itself, so it follows the variable at use.
    expect(rule(css, ".p-3")).toContain("calc(var(--grid-base) * 3)");
    expect(rule(css, ".rounded-md")).toContain("var(--ds-radius-md)");
    expect(rule(css, ".text-body")).toContain("font-size: var(--text-body)");
    expect(rule(css, ".text-body")).toContain("var(--text-body--line-height)");
    expect(rule(css, ".bg-hover")).toContain("var(--ds-color-hover)");
    expect(rule(css, ".text-muted")).toContain("var(--ds-color-muted)");
    expect(rule(css, ".shadow-elevation-2")).toContain("var(--elevation-2)");
    expect(rule(css, ".duration-quick")).toContain("var(--cmux-motion-quick)");
    expect(rule(css, ".ease-standard")).toContain("var(--cmux-ease-out)");
  });

  test("every variable the theme names is defined in desktop.css", () => {
    const begin = desktop.indexOf("/* design-scale:begin");
    const end = desktop.indexOf("/* design-scale:end */");
    expect(begin).toBeGreaterThan(-1);
    expect(end).toBeGreaterThan(begin);
    const named = new Set([...theme.matchAll(/var\((--[a-z0-9-]+)\)/g)].map((match) => match[1]!));
    const missing = [...named].filter((name) => !new RegExp(`(^|[\\s;{])${name}\\s*:`, "m").test(desktop));
    expect(missing).toEqual([]);
  });

  test("shared spacing, icons, controls and radii track the interface-scale grid", () => {
    const block = desktop.slice(desktop.indexOf("/* design-scale:begin"), desktop.indexOf("/* design-scale:end */"));
    const design = JSON.parse(
      fs.readFileSync(path.resolve(src, "../../schemas/design-scale/design-scale.json"), "utf8"),
    ) as {
      spacing: { steps: { name: string; px: number }[]; layout: number[] };
      controls: { name: string; px: number }[];
      icons: { name: string; px: number }[];
      radii: { name: string; px: number }[];
      namedRadii: { name: string; px?: number; var?: string }[];
    };
    expect(desktop).toContain("--grid-base: calc(4px * var(--cmux-interface-scale, 1))");
    expect(desktop).toContain("--grid-row: calc(28px * var(--cmux-interface-scale, 1))");
    // --ds-space-3, Tailwind p-3 and the native 4-point grid now all resolve
    // to 12px at 100%, 15px at 125%, and 18px at 150%.
    for (const { name, px } of design.spacing.steps) {
      expect(px % 4).toBe(0);
      expect(block).toContain(`--ds-space-${name}: calc(var(--grid-base) * ${px / 4});`);
    }
    for (const px of design.spacing.layout) {
      expect(block).toContain(`--ds-space-${px}: calc(var(--grid-base) * ${px / 4});`);
    }
    // Named 5/6 steps deliberately denote 24/32px, so their Tailwind peers
    // are p-6/p-8, not p-5/p-6.
    for (const [family, rows] of [
      ["control", design.controls],
      ["icon", design.icons],
      ["radius", [...design.radii, ...design.namedRadii]],
    ] as const) {
      for (const item of rows) {
        if (item.px === undefined) continue; // menu radius comes from AppKit
        expect(block).toContain(
          `--ds-${family}-${item.name}: calc(${item.px}px * var(--cmux-interface-scale, 1));`,
        );
      }
    }
  });
  test("elevation has a dark value under both dark selectors", () => {
    const block = desktop.slice(desktop.indexOf("/* design-scale:begin"), desktop.indexOf("/* design-scale:end */"));
    expect(block).toContain(':root:not([data-theme="light"])');
    expect(block).toContain(':root[data-theme="dark"]');
  });
});
