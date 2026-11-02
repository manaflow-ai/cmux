// The chat header's top-right icons are plain glyphs (Leo 2026-10-25: "why do the icons have their own
// background border situation instead of just being, you know, good"; Leo 2026-10-31: "AND THE FUCKING
// BACKGROUND ON THIS FUCKING BUILD ON THESE BUTTONS STILL ISN'T FUCKING REMOVESD"): no rule for a header
// tool draws a fill, a border or a shadow behind it, at rest, on hover, while its menu is open or while
// pressed, in the chat header, the tab row or Start Agent's floating chat. An open panel's toggle reads as
// on by the lit ink alone, as the App's pane toolbar toggles do (Leo, 2026-10-29: "i literally meant the
// ui depicting it as toggled or not"); the keyboard focus ring stays. The same states are checked in a
// real browser by chat-header-tab-row-surface.test.ts.
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

test("no header tool draws a fill, border or shadow of its own in any state", () => {
  const boxed: string[] = [];
  for (const { file, selector, body } of rules()) {
    if (!selector.split(",").some((part) => HEADER_TOOL.test(part))) continue;
    for (const [property, value] of body) {
      const fill = (property === "background" || property === "background-color") && !NO_FILL.test(value);
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
  // focus rule answers with an important `background:none`, which is no fill.
  const focus = rules().find(
    ({ file, selector }) =>
      file === "header/header.css" &&
      selector.split(",").includes(".acpmux-header-tools .acpmux-header-tool:focus-visible"),
  );
  expect(focus?.body.get("background")).toBe("none");
  expect(focus?.body.get("outline")).toMatch(/solid/);
});

test("an open panel's toggle reads as on by its lit ink with no plate, and focus keeps its ring", () => {
  const all = rules().filter(({ file }) => file === "header/header.css");
  const rule = (selector: string) => all.find((candidate) => candidate.selector === selector)?.body;
  const rest = rule(".acpmux-header-tools .acpmux-header-tool")?.get("color");
  const hover = rule(
    ".acpmux-header-tools .acpmux-header-tool:not(:disabled):hover,.acpmux-header-tools .acpmux-header-tool[data-popup-open]",
  )?.get("color");
  // Hovered too: the hover rule outranks a bare [aria-pressed] selector, so the pressed rule names it.
  const pressed = rule(
    ".acpmux-header-tools .acpmux-header-tool[aria-pressed=true],.acpmux-header-tools .acpmux-header-tool[aria-pressed=true]:not(:disabled):hover",
  );
  expect(rest).toBe("var(--agent-muted)");
  expect(hover).toBe("var(--agent-text)");
  // On differs from hover: the lit ink, not the text's ink, and nothing behind the glyph.
  expect(pressed?.get("color")).toMatch(LIT_INK);
  expect(pressed?.has("background")).toBe(false);
  expect(pressed?.has("background-color")).toBe(false);
  const focus = all.find(({ selector }) => selector === ".acpmux-header-tool:focus-visible")?.body.get("outline");
  expect(focus).toMatch(/solid/);
});
