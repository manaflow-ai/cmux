// The tooltip refresh (experiments.hoverLook, off by default): off, the root carries no
// data-hover-look and the App's glass draws under every hover surface as before; on, the root carries
// the default arm, and the page paints its tooltips and hover cards itself. Its CSS is paint only:
// it never sets a property that sizes a tooltip.
/// <reference types="bun" />
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";
import { setExperimentSwitches } from "../src/experiments/switches";
import { installHoverLook, pageDrawsHover } from "../src/ui/hoverLook";
import { HOVER_LOOK_ATTRIBUTE, HOVER_LOOK_SWITCH, hoverLook } from "../src/ui/hoverLook.experiment";

afterEach(() => setExperimentSwitches({}));

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
