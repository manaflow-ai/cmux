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
// A selector list's parts, split at its top-level commas only (not inside `:is(…)` or `:not(…)`).
function parts(selector: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < selector.length; index += 1) {
    const char = selector[index];
    if (char === "(") depth += 1;
    else if (char === ")") depth -= 1;
    else if (char === "," && depth === 0) {
      out.push(selector.slice(start, index).trim());
      start = index + 1;
    }
  }
  out.push(selector.slice(start).trim());
  return out;
}
// Whether a part names a lit state outside a `:not(…)` (`:not(:hover)` is not one).
const lit = (part: string) => LIT_STATE.test(part.replace(/:not\((?:[^()]|\([^()]*\))*\)/g, ""));
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
    const tools = parts(selector).filter((part) => HEADER_TOOL.test(part));
    if (tools.length === 0) continue;
    for (const [property, value] of body) {
      // A fill only in a lit state: every header-tool part of the rule names one.
      const fill = isFill(property, value) && !tools.every(lit);
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
      parts(selector).includes(".acpmux-header-tools .acpmux-header-tool:focus-visible"),
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
        parts(selector).some(
          (part) => part.startsWith(`${host} .acpmux-header-tool`) && lit(part) && /\[aria-pressed=true\]/.test(part),
        ) && [...body].some(([property, value]) => isFill(property, value)),
    );
    expect(filled ? host : `${host}: no pressed fill`).toBe(host);
  }
  // The hover pill never paints over an on toggle's square (it would lighten it): each hover fill either
  // excludes a pressed tool, or a pressed fill for the same host comes after it and is at least as specific
  // (#32703's form: `:not(:disabled):is([aria-pressed=true],...)` after `:not(:disabled):hover`).
  const fills = all.flatMap(({ selector, body }, index) =>
    [...body].some(([property, value]) => isFill(property, value))
      ? parts(selector).map((part) => ({ part, index }))
      : [],
  );
  const hoverFills = fills.filter(
    ({ part }) =>
      HEADER_TOOL.test(part) &&
      /:hover/.test(part) &&
      !/\[aria-pressed=true\]/.test(part.replace(/:not\((?:[^()]|\([^()]*\))*\)/g, "")),
  );
  expect(hoverFills.length).toBeGreaterThan(0);
  const hostOf = (part: string) => part.split(" .acpmux-header-tool")[0];
  const pressedWins = ({ part, index }: { part: string; index: number }) =>
    /:not\([^)]*\[aria-pressed=true\]/.test(part) ||
    fills.some(
      (fill) =>
        fill.index > index &&
        hostOf(fill.part) === hostOf(part) &&
        /\[aria-pressed=true\]/.test(fill.part) &&
        (!/:not\(:disabled\)/.test(part) || /:not\(:disabled\)/.test(fill.part)),
    );
  expect(hoverFills.filter((fill) => !pressedWins(fill)).map(({ part }) => part)).toEqual([]);
  const focus = all.find(({ selector }) => selector === ".acpmux-header-tool:focus-visible")?.body.get("outline");
  expect(focus).toMatch(/solid/);
});
