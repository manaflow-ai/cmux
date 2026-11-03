// The chat header's top-right icons are plain glyphs at rest (Leo 2026-10-25: "why do the icons have their
// own background border situation instead of just being, you know, good"; Leo 2026-10-31: "AND THE
// FUCKING BACKGROUND ON THIS FUCKING BUILD ON THESE BUTTONS STILL ISN'T FUCKING REMOVESD"): no rule for a
// header tool draws a fill at rest, nor a border or shadow in any state, in the chat header, the tab row
// or Start Agent's floating chat. The pointer's icon gets the hover pill, and an open panel's toggle (or a
// button holding its open menu) gets the filled rounded square with the lit ink (Leo 2026-11-02: "HAVE THE
// FUCKING TOGGLED HIGHLIGHT", settled by his reference image of the header with its list button
// highlighted; cmux#32687). #28962 removed the resting fill only. The keyboard focus ring stays. The same
// states are checked in a real browser by chat-header-tab-row-surface.test.ts.
// A declaration's `!important` only raises its priority: `background:none !important` is no fill.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const ACPMUX = join(import.meta.dir, "../src/agent-session/acpmux");
// A header tool button, including the shared panel toggle; not the tool row or group.
const HEADER_TOOL = /\.acpmux-header-(?:tool|panel-toggle)(?![\w-])/;
const NO_FILL = /^(none|transparent)$/;
// The pressed toggle's ink: the App's lit glyph (`--agent-lit-glyph`, Palette.litGlyph).
const LIT_INK = /^var\(--agent-lit-glyph[,)]/;
// A state that may draw the pill: the pointer on it, its panel open (pressed), or its menu open.
const LIT_STATE = /:hover|\[aria-pressed=true\]|\[data-popup-open\]/;
const isFill = (property: string, value: string) =>
  (property === "background" || property === "background-color") && !NO_FILL.test(value);

function cssFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return cssFiles(path);
    return entry.name.endsWith(".css") ? [path] : [];
  });
}

function rules(): { file: string; selector: string; body: Map<string, string> }[] {
  return cssFiles(ACPMUX).flatMap((file) => {
    const css = readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
    return [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector = "", body = ""]) => ({
      file: relative(ACPMUX, file),
      selector: selector.trim().replace(/\s+/g, " "),
      body: new Map(
        body
          .split(";")
          .map((declaration) =>
            declaration.split(/:(.*)/s).map((part) => part.replace(/\s*!important\s*$/i, "").trim()),
          )
          .filter(([property, value]) => property && value)
          .map(([property, value]) => [property!, value!]),
      ),
    }));
  });
}

test("no header tool draws a fill at rest, nor a border or shadow in any state", () => {
  const boxed: string[] = [];
  for (const { file, selector, body } of rules()) {
    const parts = selector.split(",").filter((part) => HEADER_TOOL.test(part));
    if (parts.length === 0) continue;
    for (const [property, value] of body) {
      // A fill only in a lit state: every header-tool part of the rule names one.
      const fill = isFill(property, value) && !parts.every((part) => LIT_STATE.test(part));
      const border =
        /^border(-(top|right|bottom|left|width|style|color))?$/.test(property) && !/^(0|none)$/.test(value);
      const shadow = property === "box-shadow" && value !== "none";
      if (fill || border || shadow) boxed.push(`${file}: ${selector} { ${property}: ${value} }`);
    }
  }
  expect(boxed).toEqual([]);
});

test("the header tools' focus rule clears the shared focus gradient without drawing a fill", () => {
  // shared/styles.css paints an important gradient on a focused button; the header tool's own
  // focus rule answers with an important `background-image:none`, and draws no fill of its own.
  const focus = rules().find(
    ({ file, selector }) =>
      file === "header/header.css" &&
      selector.split(",").includes(".acpmux-header-tools .acpmux-header-tool:focus-visible"),
  );
  expect(focus?.body.get("background-image")).toBe("none");
  for (const [property, value] of focus?.body ?? []) expect(isFill(property, value)).toBe(false);
  expect(focus?.body.get("outline")).toMatch(/solid/);
});

test("an open panel's toggle reads as on by the filled rounded square and its lit ink, and focus keeps its ring", () => {
  const all = rules().filter(({ file }) => file === "header/header.css");
  const rule = (selector: string) => all.find((candidate) => candidate.selector === selector)?.body;
  const rest = rule(".acpmux-header-tools .acpmux-header-tool");
  const hover = rule(
    ".acpmux-header-tools .acpmux-header-tool:not(:disabled):hover,.acpmux-header-tools .acpmux-header-tool[data-popup-open]",
  )?.get("color");
  // Hovered too: the hover rule outranks a bare [aria-pressed] selector, so the pressed rule names it.
  const pressedInk = rule(
    ".acpmux-header-tools .acpmux-header-tool[aria-pressed=true],.acpmux-header-tools .acpmux-header-tool[aria-pressed=true]:not(:disabled):hover",
  );
  expect(rest?.get("color")).toBe("var(--agent-muted)");
  expect([...(rest ?? [])].some(([property, value]) => isFill(property, value))).toBe(false);
  expect(hover).toBe("var(--agent-text)");
  expect(pressedInk?.get("color")).toMatch(LIT_INK);
  // The fill: a rule for a pressed tool in the chat header, the tab row and the floating chat.
  for (const host of [".acpmux-header-tools", ".acpmux-floating-header", ".acpmux-floating-bar"]) {
    const filled = all.some(
      ({ selector, body }) =>
        selector
          .split(",")
          .some((part) => part.startsWith(`${host} .acpmux-header-tool`) && /\[aria-pressed=true\]/.test(part)) &&
        [...body].some(([property, value]) => isFill(property, value)),
    );
    expect(filled ? host : `${host}: no pressed fill`).toBe(host);
  }
  const focus = all.find(({ selector }) => selector === ".acpmux-header-tool:focus-visible")?.body.get("outline");
  expect(focus).toMatch(/solid/);
});
