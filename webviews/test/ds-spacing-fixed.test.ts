import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import scale from "../../schemas/design-scale/design-scale.json";
import { designTokenValue } from "../scripts/design-token-values";

const source = (name: string) => readFileSync(path.resolve(import.meta.dir, "../src", name), "utf8");

test("page and standalone kit entry points load the fixed spacing scale", () => {
  const desktop = source("pages/shared/desktop.css");
  const standalone = source("pages/shared/fixed-spacing.css");
  expect(source("kit/kit.css")).toContain('@import "../pages/shared/fixed-spacing.css"');
  const steps = [...scale.spacing.steps, ...scale.spacing.layout.map((px) => ({ name: String(px), px }))];
  for (const { name, px } of steps) {
    const declaration = `--ds-space-fixed-${name}: ${px}px;`;
    expect(desktop).toContain(declaration);
    expect(standalone).toContain(declaration);
    expect(designTokenValue(`--ds-space-fixed-${name}`)).toBe(`${px}px`);
  }
  expect(source("pages/shared/pageDensity.css")).not.toContain("--ds-space-fixed-");
});
