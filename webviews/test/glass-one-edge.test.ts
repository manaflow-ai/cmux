// Liquid glass draws its own edge: `--glass-rim-shadow` (ui/glass/glass.css) is one inset hairline
// under plain glass and Reduce Transparency, the specular rim under the lens. A glass surface that
// keeps the border it had as a solid surface draws two edges, the border outside the rim (the Add
// project dialog and the icon picker's pills after #23477). A glass element's border is either gone
// or clear, as `.ui-card.ui-glass` keeps its width but not its colour (pages/shared/desktop.css), so
// the rim is its one edge.
//
// The check reads the sources: the class list of each `.ui-glass` element (its className in the
// TSX), then every stylesheet rule whose subject that element matches. Some rule must clear the
// border (width 0 or none, or a transparent colour) wherever another draws one.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const source = path.resolve(import.meta.dir, "../src");

const files = (dir: string, ext: RegExp): string[] =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) return files(file, ext);
    return ext.test(entry.name) && !entry.name.includes(".gallery.") ? [file] : [];
  });

// Each glass element's class list, from every string literal in the sources that names ui-glass.
const elements = new Map<string, string[]>();
for (const file of files(source, /\.tsx?$/)) {
  for (const match of fs.readFileSync(file, "utf8").matchAll(/["`]([^"`\n]*)["`]/g)) {
    const names = match[1].split(/\s+/).filter((name) => /^[a-z][\w-]*$/.test(name));
    if (names.includes("ui-glass") && names.length > 1)
      elements.set(`${path.relative(source, file)}: ${names.join(" ")}`, names);
  }
}

const css = files(source, /\.css$/).map((file) => ({
  file: path.relative(source, file),
  text: fs.readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, ""),
}));

// The text with every parenthesized group removed (:not(...), :is(...), attribute values stay out).
const flat = (value: string) => {
  let out = "";
  let depth = 0;
  for (const char of value) {
    if (char === "(") depth++;
    else if (char === ")") depth--;
    else if (depth === 0) out += char;
  }
  return out;
};

// Every rule's selectors and the border it declares: drawn (a width and a visible colour) or cleared.
const rules = css.flatMap(({ file, text }) =>
  [...text.matchAll(/([^{}]+)\{([^{}]*)\}/g)].flatMap((rule) => {
    const body = rule[2];
    const shorthand = [...body.matchAll(/(?:^|[;{\s])border\s*:\s*([^;}]+)/g)].map((m) => m[1].trim());
    const widths = [...body.matchAll(/(?:^|[;{\s])border-width\s*:\s*([^;}]+)/g)].map((m) => m[1].trim());
    const colors = [...body.matchAll(/(?:^|[;{\s])border-color\s*:\s*([^;}]+)/g)].map((m) => m[1].trim());
    const none = (value: string) => /^(0(px)?|none)(\s*!important)?$/.test(value);
    const cleared =
      [...shorthand, ...widths].some(none) ||
      [...shorthand, ...colors].some((value) => /(^|\s)transparent(\s|$|!)/.test(value));
    const drawn = !cleared && [...shorthand, ...widths].some((value) => !none(value));
    if (!cleared && !drawn) return [];
    // The subject compound of each selector: its classes, and whether it is a pseudo-element.
    return flat(rule[1])
      .split(",")
      .map(
        (selector) =>
          selector
            .trim()
            .split(/[\s>+~]+/)
            .at(-1) ?? "",
      )
      .filter((subject) => !subject.includes("::"))
      .map((subject) => ({
        file,
        subject,
        classes: [...subject.matchAll(/\.([\w-]+)/g)].map((m) => m[1]),
        drawn,
        cleared,
      }))
      .filter((use) => use.classes.length > 0);
  }),
);

describe("liquid glass draws one edge", () => {
  test("the glass surfaces are found", () => {
    const all = [...elements.values()].flat();
    for (const name of [
      "acpmux-add-project-dialog",
      "icon-bar-pill",
      "acpmux-composer-box",
      "acpmux-session-hover-card",
    ])
      expect(all).toContain(name);
  });

  test("no glass element keeps a visible border of its own over the glass rim", () => {
    const doubled = [...elements].flatMap(([element, names]) => {
      const matching = rules.filter((rule) => rule.classes.every((name) => names.includes(name)));
      if (matching.some((rule) => rule.cleared)) return [];
      return matching.filter((rule) => rule.drawn).map((rule) => `${element} <- ${rule.file}: ${rule.subject}`);
    });
    expect(doubled).toEqual([]);
  });
});
