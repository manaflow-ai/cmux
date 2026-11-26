import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const src = path.resolve(import.meta.dir, "../src");
const desktop = fs.readFileSync(path.join(src, "pages/shared/desktop.css"), "utf8");
const fixed = fs.readFileSync(path.join(src, "pages/shared/fixed-spacing.css"), "utf8");
const density = fs.readFileSync(path.join(src, "pages/shared/pageDensity.css"), "utf8");
const scale = JSON.parse(
  fs.readFileSync(path.resolve(import.meta.dir, "../../schemas/design-scale/design-scale.json"), "utf8"),
) as { spacing: { steps: Array<{ name: string; px: number }>; layout: number[] } };
const expected: Record<string, number> = Object.fromEntries([
  ...scale.spacing.steps.map((step) => [step.name, step.px]),
  ...scale.spacing.layout.map((px) => [String(px), px]),
]);
const spacingProperty =
  /^(?:(?:padding|margin)(?:-(?:top|right|bottom|left|block(?:-(?:start|end))?|inline(?:-(?:start|end))?))?|gap|row-gap|column-gap)$/;

function cssFiles(): string[] {
  const files: string[] = [];
  const visit = (dir: string) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(full);
      else if (entry.name.endsWith(".css") && !entry.name.endsWith(".generated.css")) files.push(full);
    }
  };
  visit(src);
  return files.filter(
    (file) => !file.endsWith("/pages/shared/desktop.css") && !file.endsWith("/pages/shared/pageDensity.css"),
  );
}

describe("fixed design spacing migration", () => {
  test("nominal aliases are generated from the Instrument scale", () => {
    expect(desktop).toContain('@import "./fixed-spacing.css";');
    for (const [name, px] of Object.entries(expected)) {
      expect(fixed).toContain(`--ds-space-fixed-${name}: ${px}px;`);
      expect(desktop).not.toContain(`--ds-space-fixed-${name}:`);
    }
  });

  test("density overrides leave nominal aliases stable", () => {
    expect(density).not.toContain("--ds-space-fixed-");
    expect(fixed).toContain("fixed-spacing:begin");
    const references = cssFiles().flatMap((file) => {
      const css = fs.readFileSync(file, "utf8");
      return [...css.matchAll(/(?:^|[;{])\s*([a-z-]+)\s*:\s*([^;{}]*--ds-space-fixed-[^;{}]*)/g)].map((m) => ({
        file,
        property: m[1]!,
        value: m[2]!,
      }));
    });
    expect(references.length).toBeGreaterThan(0);
    for (const reference of references) expect(spacingProperty.test(reference.property)).toBe(true);
    for (const reference of references) {
      expect(reference.value).not.toMatch(/var\(--ds-space-fixed-\d+,/);
      for (const match of reference.value.matchAll(/var\(--ds-space-fixed-(\d+)\)/g)) {
        expect(expected[match[1]!]).toBeDefined();
      }
    }
  });
});
