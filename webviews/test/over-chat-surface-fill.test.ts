// A surface that lies over the chat never takes its fill from the page color. `--agent-page-bg`
// (AgentPaneTheme.pageColor) is clear in a translucent window, where the window root paints the one
// backdrop, so a dialog or the overlay Inspector filled with it showed the transcript through it,
// unblurred: the Inspector before #23477 and the PDF attachment viewer after it. Such a surface is the
// liquid glass (.ui-glass) or mixes from the opaque surface (`--cmux-surface-solid`); the page color
// may stay only as a var() fallback for a page with no host theme.
//
// The check reads the sources: the classes each agent-pane `<Dialog>` and `.ui-glass` element gets
// (its className in the TSX), and the overlay Inspector, then every stylesheet rule whose selector
// names one of those classes. Rules for the pushed Inspector (`data-placement="push"`), a column
// beside the chat on its own page, are not over the chat and are not checked.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const source = path.resolve(import.meta.dir, "../src/agent-session");

const files = (dir: string, ext: RegExp): string[] =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) return files(file, ext);
    return ext.test(entry.name) && !entry.name.includes(".gallery.") ? [file] : [];
  });

const classNames = (list: string) => list.split(/\s+/).filter((name) => /^[a-z][\w-]*$/.test(name));
const shared = new Set(["ui-glass", "ui-glass-floats", "ui-popup", "ui-dialog", "ui-card"]);

// The attributes of the JSX tag that opens at `start`: up to its `>` outside any `{...}` (an arrow
// function in a prop has a `>` of its own), as glass-one-edge.test.ts reads them.
const attributes = (text: string, start: number) => {
  let depth = 0;
  for (let i = start; i < text.length; i++) {
    if (text[i] === "{") depth++;
    else if (text[i] === "}") depth--;
    else if (text[i] === ">" && depth === 0 && text[i - 1] !== "=") return text.slice(start, i);
  }
  return text.slice(start);
};

// The classes of every surface over the chat: a <Dialog>'s className, a .ui-glass element's, and
// the overlay Inspector (ChatInspector.tsx gives it its class only in a ternary).
const surfaces = new Set<string>(["acpmux-chat-inspector"]);
for (const file of files(source, /\.tsx$/)) {
  const text = fs.readFileSync(file, "utf8");
  for (const open of text.matchAll(/<Dialog\b/g)) {
    const className = attributes(text, open.index).match(/\bclassName="([^"]+)"/);
    for (const name of classNames(className?.[1] ?? "")) if (!shared.has(name)) surfaces.add(name);
  }
  for (const literal of text.matchAll(/["`]([^"`\n]*\bui-glass\b[^"`\n]*)["`]/g)) {
    // Only the surface's own class; the utility classes beside it (flex, text-fg) are not surfaces.
    for (const name of classNames(literal[1])) if (/^(acpmux|cv)-/.test(name)) surfaces.add(name);
  }
}

// The page color as the fill itself, not as the fallback of another token (`var(--x, var(--agent-page-bg))`).
const pageColorFill = (value: string) =>
  [...value.matchAll(/var\(\s*--agent-page-bg\b/g)].some((match) => {
    // A fallback only when the comma closes a `var(--x,` argument; in `color-mix(in srgb, ...)` the
    // page color is the mix's own color.
    return !/var\(\s*--[\w-]+\s*,\s*$/.test(value.slice(0, match.index));
  });

test("finds the dialogs and glass surfaces over the chat", () => {
  for (const name of ["acpmux-pdf-viewer", "acpmux-image-viewer", "acpmux-chat-gallery", "acpmux-add-project-dialog"]) {
    expect(surfaces.has(name)).toBe(true);
  }
});

test("no surface over the chat fills with the page color, which is clear in a translucent window", () => {
  const offenders: string[] = [];
  for (const file of files(source, /\.css$/)) {
    const css = fs.readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
    for (const rule of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const selector = rule[1].trim();
      if (selector.includes('data-placement="push"') || selector.includes("data-placement=push")) continue;
      const named = selector.match(/\.[a-z][\w-]*/g)?.map((name) => name.slice(1)) ?? [];
      if (!named.some((name) => surfaces.has(name))) continue;
      // Only the surface's own fill: a descendant (a row, a tab) lies on the surface, not over the chat.
      const subject = selector.split(",").some((part) => {
        const last =
          part
            .trim()
            .split(/\s+|>|~|\+/)
            .filter(Boolean)
            .at(-1) ?? "";
        return (last.match(/\.[a-z][\w-]*/g) ?? []).some((name) => surfaces.has(name.slice(1)));
      });
      if (!subject) continue;
      for (const decl of rule[2].matchAll(/(?:^|;)\s*(background(?:-color)?)\s*:\s*([^;]+)/g)) {
        if (pageColorFill(decl[2])) {
          const line = css.slice(0, rule.index).split("\n").length;
          offenders.push(`${path.relative(source, file)}:${line} ${selector} { ${decl[1]}: ${decl[2].trim()} }`);
        }
      }
    }
  }
  expect(offenders).toEqual([]);
});
