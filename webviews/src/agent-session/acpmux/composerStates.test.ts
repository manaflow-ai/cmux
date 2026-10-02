import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

// The composer's interaction states (composerStates.css) change only paint, so a hover or a
// press never moves a neighbor, and time only through the host's motion tokens.
const css = readFileSync(new URL("./composerStates.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector, body]) => ({
  selector: selector!.trim(),
  declarations: body!
    .split(";")
    .map((declaration) => declaration.trim())
    .filter(Boolean)
    .map((declaration) => {
      const colon = declaration.indexOf(":");
      return { property: declaration.slice(0, colon).trim(), value: declaration.slice(colon + 1).trim() };
    }),
}));

test("hover and press rules change only paint, never size, spacing or borders", () => {
  const paint = new Set(["background", "background-color", "color", "opacity", "box-shadow", "outline-color"]);
  const states = rules.filter((rule) => /:(hover|active)/.test(rule.selector));
  expect(states.length).toBeGreaterThan(0);
  for (const rule of states) {
    for (const { property } of rule.declarations)
      expect(`${rule.selector} ${property}`).toBe(
        `${rule.selector} ${paint.has(property) ? property : "(paint only)"}`,
      );
  }
});

test("every transition and animation runs on a motion token with the ease-out curve", () => {
  const timed = rules.flatMap((rule) =>
    rule.declarations.filter(({ property }) => property === "transition" || property === "animation"),
  );
  expect(timed.length).toBeGreaterThan(0);
  for (const { value } of timed) {
    for (const part of value.split(",")) {
      expect(part).toMatch(/var\(--agent-motion-(hover|focus|in|out)\) var\(--agent-ease-out\)/);
      expect(part).not.toMatch(/\d+m?s\b/);
    }
  }
});

// These mirror MotionFade in Packages/macOS/CmuxNext (CmuxNextDesign/Motion/MotionFadeTokens.swift); the host overrides them through the theme.
test("the motion tokens default to the host's fast fades", () => {
  const root = rules.find((rule) => rule.selector === ":root")!;
  const tokens = Object.fromEntries(root.declarations.map(({ property, value }) => [property, value]));
  expect(tokens).toMatchObject({
    "--agent-motion-hover": "80ms",
    "--agent-motion-focus": "100ms",
    "--agent-motion-in": "120ms",
    "--agent-motion-out": "80ms",
  });
});
