// Grid line heights (experiments.typeGrid, off by default; design C1): off, the root carries no
// data-type-grid and every line height is today's; on, it does. ui/typeGrid.css sets each step to
// round4(1.45 x size) from schemas/type-scale/type-scale.json, and overrides the line height tokens at
// every scope that sets them (a new scope that sets one fails here until typeGrid.css covers it).
/// <reference types="bun" />
import { afterEach, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { Window } from "happy-dom";
import { setExperimentSwitches } from "../src/experiments/switches";
import { gridLineHeight, installTypeGrid, TYPE_GRID_ATTRIBUTE, TYPE_GRID_SWITCH } from "../src/ui/typeGrid";

afterEach(() => setExperimentSwitches({}));

const SRC = join(import.meta.dir, "../src");
const GRID_CSS = readFileSync(join(SRC, "ui/typeGrid.css"), "utf8");
const scale = JSON.parse(readFileSync(join(import.meta.dir, "../../schemas/type-scale/type-scale.json"), "utf8")) as {
  steps: { name: string; size: number; lineHeight: number }[];
};
const DECL = /--text-([a-z]+)--line-height:\s*calc\((\d+(?:\.\d+)?)px \* var\((--[a-z-]+)/g;

function declarations(css: string): { step: string; px: number; scaleVar: string }[] {
  return [...css.matchAll(DECL)].map((m) => ({ step: m[1], px: Number(m[2]), scaleVar: m[3] }));
}

function cssFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return cssFiles(path);
    return name.endsWith(".css") ? [path] : [];
  });
}

test("off by default; the switch sets data-type-grid and clears it live", () => {
  const doc = new Window().document as unknown as Document;
  const stop = installTypeGrid(doc);
  expect(doc.documentElement.hasAttribute(TYPE_GRID_ATTRIBUTE)).toBe(false);
  setExperimentSwitches({ [TYPE_GRID_SWITCH]: true });
  expect(doc.documentElement.hasAttribute(TYPE_GRID_ATTRIBUTE)).toBe(true);
  setExperimentSwitches({});
  expect(doc.documentElement.hasAttribute(TYPE_GRID_ATTRIBUTE)).toBe(false);
  stop();
});

test("design C1's table: 11/16, 12/16, 13/20, 14/20, 15/20, 20/28, every one on the 4 grid", () => {
  expect([11, 12, 13, 14, 15, 20].map(gridLineHeight)).toEqual([16, 16, 20, 20, 20, 28]);
  for (const step of scale.steps) expect(gridLineHeight(step.size) % 4).toBe(0);
});

test("every line height in typeGrid.css is round4(1.45 x size) of its step", () => {
  const sizes = new Map(scale.steps.map((step) => [step.name, step.size]));
  const found = declarations(GRID_CSS);
  expect(found.length).toBeGreaterThan(0);
  for (const { step, px } of found) expect({ step, px }).toEqual({ step, px: gridLineHeight(sizes.get(step)!) });
  // The page root covers every step of the scale.
  const root = new Set(found.filter((d) => d.scaleVar === "--cmux-interface-scale").map((d) => d.step));
  expect([...root].sort()).toEqual(scale.steps.map((step) => step.name).sort());
});

test("every scope that sets a line height token is overridden at its own scale", () => {
  const covered = new Set(declarations(GRID_CSS).map((d) => `${d.step} ${d.scaleVar}`));
  const missing: string[] = [];
  for (const file of cssFiles(SRC)) {
    if (file.endsWith("ui/typeGrid.css")) continue;
    for (const d of declarations(readFileSync(file, "utf8")))
      if (!covered.has(`${d.step} ${d.scaleVar}`))
        missing.push(`${file.slice(SRC.length + 1)}: ${d.step} x ${d.scaleVar}`);
  }
  expect(missing).toEqual([]);
});
