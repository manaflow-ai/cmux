// The chat header's top-right icons are plain glyphs (Leo 2026-10-25: "why do the icons have their own
// background border situation instead of just being, you know, good"): no rule for a header tool draws
// a fill, a border or a shadow behind it, at rest, on hover, while its menu is open or while its panel
// is open. The open panel's toggle still reads as on through its ink: the text color over the muted
// rest, and the keyboard focus ring stays. Start Agent's floating chat borrows the tool's square and
// keeps its own tint, in rules scoped to its header and bar. The gallery's header-tools plain-icons
// play checks the computed styles in a real browser.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const ACPMUX = join(import.meta.dir, "../src/agent-session/acpmux");
// A header tool button: `.acpmux-header-tool`, not `.acpmux-header-tools` or `.acpmux-header-tool-group`.
const HEADER_TOOL = /\.acpmux-header-tool(?![\w-])/;
// The floating chat's header and folded bar (FloatingChat.tsx), not the chat header.
const FLOATING = /^\.acpmux-floating-(header|bar) /;
const NO_FILL = /^(none|transparent)$/;

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
          .map((declaration) => declaration.split(/:(.*)/s).map((part) => part.trim()))
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
      const fill = (property === "background" || property === "background-color") && !NO_FILL.test(value);
      const border =
        /^border(-(top|right|bottom|left|width|style|color))?$/.test(property) && !/^(0|none)$/.test(value);
      const shadow = property === "box-shadow" && value !== "none";
      if (fill || border || shadow) boxed.push(`${file}: ${selector} { ${property}: ${value} }`);
    }
  }
  expect(boxed).toEqual([]);
});

test("an open panel's toggle reads as on by its ink, and focus keeps its ring", () => {
  const all = rules().filter(({ file }) => file === "header/header.css");
  const color = (selector: string) => all.find((rule) => rule.selector === selector)?.body.get("color");
  const rest = color(".acpmux-header-tools .acpmux-header-tool");
  const pressed = color(".acpmux-header-tools .acpmux-header-tool[aria-pressed=true]");
  expect(rest).toBe("var(--agent-muted)");
  expect(pressed).toBe("var(--agent-text)");
  const focus = all.find(({ selector }) => selector === ".acpmux-header-tool:focus-visible")?.body.get("outline");
  expect(focus).toMatch(/solid/);
});
