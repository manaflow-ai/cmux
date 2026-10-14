// Coherence passes #20188 and #20213 (2026-10-13) gave the pane's menus and popovers
// `--acpmux-popup-elevation`: a 0.5px composer-edge hairline over `--ui-popup-shadow`, which already
// draws a 0.5px hairline of its own. Those popups drew two edges. Every web menu and popover draws
// exactly one: the hairline in `--ui-popup-shadow` (ui/popupSurface.css).
//
// The check reads the stylesheets: each `box-shadow` that uses a popup token is expanded through
// the popup tokens' definitions and must hold one inset hairline layer.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const source = path.resolve(import.meta.dir, "../src");

const sheets = (dir: string): string[] =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) return sheets(file);
    return entry.name.endsWith(".css") ? [file] : [];
  });

const css = sheets(source).map((file) => ({
  file: path.relative(source, file),
  text: fs.readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, ""),
}));

const POPUP_TOKENS = ["--ui-popup-shadow", "--acpmux-popup-elevation"];

// Every definition of a popup token, across every sheet.
const definitions = new Map<string, string[]>();
for (const { text } of css) {
  for (const token of POPUP_TOKENS) {
    for (const match of text.matchAll(new RegExp(`${token}\\s*:\\s*([^;}]+)`, "g"))) {
      definitions.set(token, [...(definitions.get(token) ?? []), match[1].trim()]);
    }
  }
}

// The argument list of the call that opens at `open` (the index of its "(").
const closing = (text: string, open: number) => {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === "(") depth++;
    else if (text[i] === ")" && --depth === 0) return i;
  }
  throw new Error(`unbalanced parentheses in ${text}`);
};

// Expands `var(--popup-token[, fallback])` with the token's first definition; other variables stay.
const expand = (value: string, seen: string[] = []): string => {
  let out = "";
  let rest = value;
  for (;;) {
    const at = rest.search(/var\(\s*--/);
    if (at < 0) return out + rest;
    const end = closing(rest, rest.indexOf("(", at));
    const call = rest.slice(at, end + 1);
    const name = call.match(/var\(\s*(--[\w-]+)/)![1];
    const definition = definitions.get(name)?.[0];
    if (POPUP_TOKENS.includes(name) && definition && !seen.includes(name)) {
      out += rest.slice(0, at) + expand(definition, [...seen, name]);
    } else {
      out += rest.slice(0, end + 1);
    }
    rest = rest.slice(end + 1);
  }
};

// The top-level comma-separated layers of a box-shadow (commas inside calls do not split).
const layers = (value: string) => {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "(") depth++;
    else if (value[i] === ")") depth--;
    else if (value[i] === "," && depth === 0) {
      parts.push(value.slice(start, i).trim());
      start = i + 1;
    }
  }
  return [...parts, value.slice(start).trim()];
};
const hairlines = (value: string) =>
  layers(expand(value)).filter((layer) => /^inset\s+0\s+0\s+0\s+[\d.]*\d(px)?\b/.test(layer));

// Each box-shadow that names a popup token, with the selector of its rule.
const uses = css.flatMap(({ file, text }) =>
  [...text.matchAll(/box-shadow\s*:\s*([^;}]+)/g)]
    .filter((match) => POPUP_TOKENS.some((token) => match[1].includes(`var(${token}`)))
    .map((match) => {
      const open = text.lastIndexOf("{", match.index);
      const start = Math.max(text.lastIndexOf("}", open), text.lastIndexOf(";", open)) + 1;
      return { file, selector: text.slice(start, open).trim().replace(/\s+/g, " "), value: match[1].trim() };
    }),
);

describe("web popups draw one hairline edge", () => {
  test("every popup token definition holds exactly one hairline", () => {
    for (const token of POPUP_TOKENS) {
      for (const definition of definitions.get(token) ?? []) {
        expect({ token, definition, hairlines: hairlines(definition).length }).toEqual({
          token,
          definition,
          hairlines: 1,
        });
      }
    }
  });

  test("every menu and popover box-shadow resolves to exactly one hairline", () => {
    expect(uses.length).toBeGreaterThan(0);
    for (const use of uses) {
      expect({ ...use, hairlines: hairlines(use.value).length }).toEqual({ ...use, hairlines: 1 });
    }
  });

  // The popups the coherence passes moved onto the shared elevation; each must still be covered.
  test("the pane's menus and popovers are all checked", () => {
    const selectors = uses.map((use) => use.selector).join("\n");
    for (const popup of [
      ".ui-popup.ui-context-menu",
      ":where(.ui-positioner)>.ui-popup",
      ".acpmux-context-pop",
      ".acpmux-menu",
      ".acpmux-slash-menu",
      ".acpmux-omni",
      ".acpmux-mp",
      ".acpmux-access-menu",
      ".acpmux-effort-menu",
      ".acpmux-chat-menu-popover",
      ".acpmux-pr-status",
      ".acpmux-summary-popover",
      ".acpmux-file-menu-list",
      ".nt-popover",
      ".acpmux-mp-cascade .acpmux-mp-sub",
    ]) {
      expect(selectors).toContain(popup);
    }
  });
});
