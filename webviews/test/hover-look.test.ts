// The tooltip refresh (experiments.hoverLook, off by default): off, the root carries no
// data-hover-look and the App's glass draws under every hover surface as before; on, the root carries
// the default arm, and the page paints its tooltips and hover cards itself. Its CSS is paint only:
// it never sets a property that sizes a tooltip.
/// <reference types="bun" />
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";
import { setExperimentSwitches } from "../src/experiments/switches";
import { installHoverLook, oneHoverSurface, pageDrawsHover } from "../src/ui/hoverLook";
import {
  HOVER_LOOK_ATTRIBUTE,
  HOVER_LOOK_ONE,
  HOVER_LOOK_SURFACES,
  HOVER_LOOK_SWITCH,
  hoverLook,
} from "../src/ui/hoverLook.experiment";

const hoverCss = () => readFileSync(new URL("../src/ui/hoverLook.css", import.meta.url), "utf8");

afterEach(() => {
  setExperimentSwitches({});
  delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
});

test("off by default: no attribute, and the App's glass keeps every hover surface", () => {
  const doc = new Window().document as unknown as Document;
  const stop = installHoverLook(doc);
  const tip = doc.createElement("div");
  tip.className = "ui-tooltip ui-glass";
  doc.body.append(tip);
  expect(doc.documentElement.hasAttribute(HOVER_LOOK_ATTRIBUTE)).toBe(false);
  expect(pageDrawsHover(tip)).toBe(false);
  stop();
});

test("the switch sets the default arm on the root and takes the hover surfaces off the App's glass", () => {
  const doc = new Window().document as unknown as Document;
  const stop = installHoverLook(doc);
  const tip = doc.createElement("div");
  tip.className = "ui-tooltip ui-glass";
  const menu = doc.createElement("div");
  menu.className = "ui-popup ui-glass";
  doc.body.append(tip, menu);
  setExperimentSwitches({ [HOVER_LOOK_SWITCH]: true });
  expect(doc.documentElement.getAttribute(HOVER_LOOK_ATTRIBUTE)).toBe(hoverLook.defaultArm);
  expect(pageDrawsHover(tip)).toBe(true);
  expect(pageDrawsHover(menu)).toBe(false);
  setExperimentSwitches({});
  expect(doc.documentElement.hasAttribute(HOVER_LOOK_ATTRIBUTE)).toBe(false);
  stop();
});

test("the look is paint only: no rule sets a size, padding, border width or type", () => {
  const css = readFileSync(new URL("../src/ui/hoverLook.css", import.meta.url), "utf8").replace(
    /\/\*[\s\S]*?\*\//g,
    "",
  );
  const declarations = [...css.matchAll(/(?:^|[;{])\s*([a-z-]+)\s*:/g)].map((match) => match[1]);
  const layout =
    /^(width|height|min-|max-|padding|margin|border(?!-radius)|font|line-height|gap|inset|top|left|right|bottom|display|position)/;
  expect(declarations.filter((name) => layout.test(name))).toEqual([]);
  expect(declarations.length).toBeGreaterThan(0);
});

test("each arm lands on the root, and a chart tooltip leaves the App's glass with the rest", () => {
  for (const arm of Object.keys(hoverLook.arms)) {
    (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { [hoverLook.id]: arm };
    const doc = new Window().document as unknown as Document;
    const stop = installHoverLook(doc);
    setExperimentSwitches({ [HOVER_LOOK_SWITCH]: true });
    expect(doc.documentElement.getAttribute(HOVER_LOOK_ATTRIBUTE)).toBe(arm);
    const chart = doc.createElement("div");
    chart.className = "ui-glass cu-tooltip";
    doc.body.append(chart);
    expect(pageDrawsHover(chart)).toBe(true);
    stop();
    setExperimentSwitches({});
  }
});

test("every surface the CSS paints is one the App stops drawing glass under", () => {
  const painted = new Set(
    [...hoverCss().matchAll(/\.(ui-tooltip|ui-title-tooltip|ui-hint|ui-card|cu-[a-z-]+)\b/g)].map((m) => m[1]),
  );
  const surfaces = new Set(HOVER_LOOK_SURFACES.split(",").map((s) => s.trim().slice(1)));
  expect([...painted].filter((name) => !surfaces.has(name))).toEqual([]);
});

test("Reduce Transparency keeps the opaque tooltip: the ink inversion only applies outside it", () => {
  const css = hoverCss().replace(/\/\*[\s\S]*?\*\//g, "");
  const ink = css.indexOf('[data-hover-look="ink"]:not([data-reduce-transparency])');
  expect(ink).toBeGreaterThan(0);
  expect(css.lastIndexOf("@media not (prefers-reduced-transparency: reduce)", ink)).toBeGreaterThanOrEqual(0);
  expect(css).not.toContain("!important");
});

// The One arm (Leo, 2026-11-22, softened: "multiple styles for hover previews plus bad-looking
// translucency blur, unacceptable"): every hover surface is the tooltip's veil over the transient
// frost at the tooltip's corner, and only it turns on one hover at a time. Off by default.
test("the One arm: one material for every hover surface, and only it runs one hover at a time", () => {
  expect(hoverLook.defaultArm).not.toBe(HOVER_LOOK_ONE);
  expect(Object.keys(hoverLook.arms)).toContain(HOVER_LOOK_ONE);
  const css = hoverCss().replace(/\/\*[\s\S]*?\*\//g, "");
  const rule = (selector: string) => {
    const at = css.indexOf(selector);
    expect(at, selector).toBeGreaterThanOrEqual(0);
    return css.slice(at, css.indexOf("}", at));
  };
  const all = rule(
    ':root[data-hover-look][data-hover-look="one"]\n  :is(.ui-tooltip, .ui-title-tooltip, .ui-hint, .ui-card, .cu-tooltip).ui-glass',
  );
  expect(all).toContain("--glass-tint: var(--tooltip-tint)");
  expect(all).toContain("--glass-backdrop: blur(var(--ds-transient-web-blur))");
  expect(rule(':root[data-hover-look][data-hover-look="one"] .ui-card.ui-glass')).toContain(
    "border-radius: calc(var(--role-tooltip-radius)",
  );

  const doc = new Window().document as unknown as Document;
  const stop = installHoverLook(doc);
  expect(oneHoverSurface(doc)).toBe(false);
  setExperimentSwitches({ [HOVER_LOOK_SWITCH]: true });
  expect(oneHoverSurface(doc)).toBe(false);
  stop();
  (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { [hoverLook.id]: HOVER_LOOK_ONE };
  const stopOne = installHoverLook(doc);
  expect(oneHoverSurface(doc)).toBe(true);
  setExperimentSwitches({});
  expect(oneHoverSurface(doc)).toBe(false);
  stopOne();
});

test("every arm defines the vars the shared ring and shadow read, so no arm's box-shadow goes invalid", () => {
  // An arm that left --hover-look-ring, -lit or -card-shadow unset made the shared rule's
  // box-shadow invalid at computed time: the One arm's hover card drew no ring and no shadow, and
  // white glass over a light wallpaper vanished (the #59205 readback).
  const css = hoverCss();
  const all = css.match(/:root\[data-hover-look\]\s*\{([^}]*)\}/);
  expect(all).not.toBeNull();
  for (const name of [
    "--hover-look-ring",
    "--hover-look-lit",
    "--hover-look-tooltip-shadow",
    "--hover-look-card-shadow",
  ]) {
    expect(all?.[1]).toContain(`${name}:`);
  }
  // One's restored edge is light-only: dark keeps One's shipped look.
  const one = css.match(/:root\[data-hover-look\]\[data-hover-look="one"\]\s*\{([^}]*)\}/)?.[1] ?? "";
  expect(one).toMatch(/--hover-look-ring:\s*light-dark\([^;]*,\s*transparent\)/);
});
