// Every surface role resolves to one complete set of variables, and surface.css styles only from them.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import roles from "../../schemas/surface-roles/surface-roles.json";

const read = (rel: string) => readFileSync(new URL(rel, import.meta.url), "utf8");
const glass = read("../src/ui/glass/glass.css");
const surface = read("../src/ui/surface/surface.css");
const FIELDS = ["material", "fill", "stroke", "radius", "elevation", "pad", "gap", "title-font", "body-font", "enter"];

test("every role defines every --surface-<role>-* variable, as a reference", () => {
  expect(roles.roles.map((role) => role.name)).toEqual(
    expect.arrayContaining([
      "popover",
      "menu",
      "card",
      "group",
      "toast",
      "sheet",
      "prompt",
      "tooltip",
      "hoverCard",
      "ask",
      "pill",
    ]),
  );
  for (const role of roles.roles) {
    for (const field of FIELDS) {
      const match = glass.match(new RegExp(`--surface-${role.name}-${field}:\\s*([^;]+);`));
      expect(match, `--surface-${role.name}-${field}`).not.toBeNull();
    }
  }
});

test("surface.css holds no literal colour or length of its own", () => {
  const code = surface.replace(/\/\*[\s\S]*?\*\//g, "");
  expect(code).not.toMatch(/#[0-9a-fA-F]{3,8}\b/);
  expect(code).not.toMatch(/\brgba?\(/);
  expect(code).not.toMatch(/(^|[\s:(,])-?\d*\.?\d+(px|rem|em)\b/m);
  expect(code).not.toMatch(/\b\d+ms\b/);
});
