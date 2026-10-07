import { expect, test } from "bun:test";
import styles from "./styles.css" with { type: "text" };

const source = String(styles).replace(/\/\*[\s\S]*?\*\//g, "");
/** The fades sit in the Reduce Motion guard; unwrapped so its rules parse like the rest. */
const GUARD = /@media \(prefers-reduced-motion:no-preference\)\{((?:[^{}]*\{[^}]*\})*)\}/g;
const guarded = [...source.matchAll(GUARD)].map((match) => match[1]!).join("\n");
const css = source.replace(GUARD, "$1");
/** The declarations of every rule whose selector list names `selector`. */
const declarations = (selector: string) =>
  [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)]
    .filter(([, selectors]) => selectors!.split(",").some((one) => one.trim() === selector))
    .map(([, , body]) => body!);
const CONTROLS = [
  ".acpmux-newtab-kind",
  ".acpmux-newtab-default",
  ".acpmux-newtab-all",
  ".acpmux-omni-row",
  ".acpmux-newtab .acpmux-send",
];

test("every new tab page control has a hover, a press and a focus state", () => {
  // A row's hover selects it, so its hover fill is is-selected.
  const states = [
    ".acpmux-newtab-kind:not(.is-selected):hover",
    ".acpmux-newtab-default:hover",
    ".acpmux-newtab-all:hover",
    ".acpmux-omni-row.is-selected",
    ".acpmux-newtab .acpmux-send:hover",
    ".acpmux-newtab-kind:not(.is-selected):active",
    ".acpmux-newtab-kind.is-selected:active",
    ".acpmux-newtab-default:active",
    ".acpmux-newtab-all:active",
    ".acpmux-omni-row:active",
    ".acpmux-newtab .acpmux-send:active",
    ".acpmux-newtab-kind:focus-visible",
    ".acpmux-newtab-default:focus-visible",
    ".acpmux-newtab-all:focus-visible",
    ".acpmux-send:focus-visible",
  ];
  for (const state of states) expect({ state, rules: declarations(state).length }).toEqual({ state, rules: 1 });
});

test("new tab page hovers fade on the Motion hover token and change only fills", () => {
  expect(declarations(".acpmux-newtab").join(";")).toContain("--acpmux-motion-hover:80ms");
  for (const control of CONTROLS) {
    const transition = declarations(control).find((body) => body.startsWith("transition:")) ?? "";
    expect({ control, transition }).toEqual({
      control,
      transition: expect.stringContaining("var(--acpmux-motion-hover)"),
    });
    expect(transition).not.toMatch(/width|height|padding|margin|border/);
    // Under Reduce Motion nothing fades (conversation/motion.test.ts holds the whole sheet to it).
    expect(guarded).toContain(control);
  }
  // No hover or press rule changes size, so nothing shifts.
  const states = [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)].filter(([, selectors]) =>
    /\.acpmux-(newtab|omni)[^,]*:(hover|active)/.test(selectors!),
  );
  expect(states.length).toBeGreaterThan(8);
  for (const [, , body] of states) expect(body).not.toMatch(/(^|;)(width|height|padding|margin|border|font-size):/);
  expect(declarations(".acpmux-omni-action").join(";")).toContain("transition:opacity var(--acpmux-motion-hover)");
});
