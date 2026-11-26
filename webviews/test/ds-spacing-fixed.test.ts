import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const src = path.resolve(import.meta.dir, "../src");
const desktop = fs.readFileSync(path.join(src, "pages/shared/desktop.css"), "utf8");
const density = fs.readFileSync(path.join(src, "pages/shared/pageDensity.css"), "utf8");
const expected: Record<string, number> = {
  "1": 4,
  "2": 8,
  "3": 12,
  "4": 16,
  "5": 24,
  "6": 32,
  "40": 40,
  "48": 48,
  "56": 56,
};
const spacingProperty =
  /^(?:padding(?:-(?:block|inline|top|right|bottom|left))?|margin(?:-(?:block|inline|top|right|bottom|left)(?:-(?:start|end))?)?|gap|row-gap|column-gap)$/;

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
    for (const [name, px] of Object.entries(expected)) {
      expect(desktop).toContain(`--ds-space-fixed-${name}: ${px}px;`);
    }
  });

  test("density overrides leave nominal aliases stable", () => {
    expect(density).not.toContain("--ds-space-fixed-");
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
