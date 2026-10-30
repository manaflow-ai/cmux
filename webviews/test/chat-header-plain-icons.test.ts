// The chat header's top-right icons are plain glyphs (Leo 2026-10-25: "why do the icons have their own
// background border situation instead of just being, you know, good"): no rule for a header tool draws
// a fill, a border or a shadow behind it, at rest, on hover or while its menu is open. The one fill is an
// open panel's toggle: the App's toolbar selection fill on its own square, with the text's ink, so it
// reads as on (Leo, 2026-10-29: "i literally meant the ui depicting it as toggled or not"); the keyboard
// focus ring stays. Start Agent's floating chat is plain too; its rules are
// scoped to its header and bar and checked in a real browser by chat-header-tab-row-surface.test.ts.
// A declaration's `!important` only raises its priority: `background:none !important` is no fill.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const ACPMUX = join(import.meta.dir, "../src/agent-session/acpmux");
// A header tool button, including the shared panel toggle; not the tool row or group.
const HEADER_TOOL = /\.acpmux-header-(?:tool|panel-toggle)(?![\w-])/;
// The floating chat's header and folded bar (FloatingChat.tsx), not the chat header.
const FLOATING = /^\.acpmux-floating-(header|bar) /;
const NO_FILL = /^(none|transparent)$/;
// The pressed toggle's fill: the App's selection fill (`--cmux-selection`, Palette.selectionFill).
const SELECTION_FILL = /^var\(--cmux-selection[,)]/;
const PRESSED = /\[aria-pressed=true\]/;

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
    if (!selector.split(",").some((part) => HEADER_TOOL.test(part) && !FLOATING.test(part.trim()))) continue;
    for (const [property, value] of body) {
      const pressedFill = selector.split(",").every((part) => PRESSED.test(part)) && SELECTION_FILL.test(value);
      const fill =
        (property === "background" || property === "background-color") && !NO_FILL.test(value) && !pressedFill;
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

test("an open panel's toggle reads as on by its selection fill and ink, and focus keeps its ring", () => {
  const all = rules().filter(({ file }) => file === "header/header.css");
  const color = (selector: string) => all.find((rule) => rule.selector === selector)?.body.get("color");
  const rest = color(".acpmux-header-tools .acpmux-header-tool");
  const pressed = color(".acpmux-header-tools .acpmux-header-tool[aria-pressed=true]");
  expect(rest).toBe("var(--agent-muted)");
  expect(pressed).toBe("var(--agent-text)");
  const fill = all
    .find((rule) => rule.selector === ".acpmux-header-tools .acpmux-header-tool[aria-pressed=true]")
    ?.body.get("background");
  expect(fill).toMatch(SELECTION_FILL);
  const focus = all.find(({ selector }) => selector === ".acpmux-header-tool:focus-visible")?.body.get("outline");
  expect(focus).toMatch(/solid/);
});
