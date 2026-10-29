// Coherence passes #20188 and #20213 (2026-10-13) gave the pane's menus and popovers
// `--acpmux-popup-elevation`: a 0.5px composer-edge hairline over `--ui-popup-shadow`, which already
// draws a 0.5px hairline of its own. Those popups drew two edges. Every web menu and popover draws
// exactly one: the hairline in `--ui-popup-shadow` (ui/popupSurface.css).
//
// The check reads the stylesheets: each `box-shadow` that uses a popup token is expanded through
// the popup tokens' definitions and must hold one inset hairline layer, with no border in the same
// rule (a page's `.ui-popup` and the chat find bar drew a border over that hairline).
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

// The elevations that carry the popup hairline, and the drop shadow alone (no hairline).
const RIM_TOKENS = ["--ui-popup-shadow", "--acpmux-popup-elevation"];
const POPUP_TOKENS = [...RIM_TOKENS, "--ui-popup-drop"];

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
  layers(expand(value)).filter((layer) =>
    /^inset\s+0\s+0\s+0\s+(?:[\d.]*\d(px)?\b|var\(--cmux-hairline(?![\w-]))/.test(layer),
  );

// A border drawn by the rule is an edge too: any `border`/`border-width` that is not 0 or none.
const borders = (body: string) =>
  [...body.matchAll(/(?:^|[;{\s])border(?:-width)?\s*:\s*([^;}]+)/g)]
    .map((match) => match[1].trim())
    .filter((value) => !/^(0(px)?|none)(\s*!important)?$/.test(value));

// Each box-shadow that names a popup token, with the selector and the borders of its rule.
const uses = css.flatMap(({ file, text }) =>
  [...text.matchAll(/box-shadow\s*:\s*([^;}]+)/g)]
    .filter((match) => POPUP_TOKENS.some((token) => match[1].includes(`var(${token}`)))
    .map((match) => {
      const open = text.lastIndexOf("{", match.index);
      const start = Math.max(text.lastIndexOf("}", open), text.lastIndexOf(";", open)) + 1;
      const body = text.slice(open + 1, text.indexOf("}", match.index));
      return {
        file,
        selector: text.slice(start, open).trim().replace(/\s+/g, " "),
        value: match[1].trim(),
        borders: borders(body),
      };
    }),
);

describe("web popups draw one hairline edge", () => {
  test("every popup elevation definition holds exactly one hairline", () => {
    for (const token of RIM_TOKENS) {
      for (const definition of definitions.get(token) ?? []) {
        expect({ token, definition, hairlines: hairlines(definition).length }).toEqual({
          token,
          definition,
          hairlines: 1,
        });
      }
    }
  });

  test("every menu and popover draws exactly one edge: the hairline, no border", () => {
    expect(uses.length).toBeGreaterThan(0);
    for (const use of uses) {
      const edges = hairlines(use.value).length + use.borders.length;
      expect({ ...use, edges }).toEqual({ ...use, edges: 1 });
    }
  });

  // appearance.borders none (data-borders on the root) clears the rim, as it clears the composer's.
  test("appearance.borders none clears the popup hairline", () => {
    const cleared = css.some(({ text }) =>
      [...text.matchAll(/:root\[data-borders=("none"|none)\]\s*\{([^}]*)\}/g)].some((match) =>
        /--ui-popup-edge\s*:\s*transparent/.test(match[2]),
      ),
    );
    expect(cleared).toBe(true);
  });

  // The popups the coherence passes moved onto the shared elevation; each must still be covered.
  // The New Tab suggestions (.acpmux-omni) became liquid glass in #24477 (2026-10-22); the glass
  // draws their one edge, checked with the glass popups below.
  test("the pane's menus and popovers are all checked", () => {
    const selectors = uses.map((use) => use.selector).join("\n");
    for (const popup of [".acpmux-summary-card", ".lg-palette", ".find-pill"]) {
      expect(selectors).toContain(popup);
    }
  });

  // The menus and popovers that are liquid glass (.ui-popup.ui-glass): the glass draws their one
  // edge (--glass-rim-shadow, ui/glass/glass.css: one hairline under plain glass and Reduce
  // Transparency, the specular rim under the lens) over .ui-popup's --glass-elevation, which must be
  // the drop alone. None of them may set a box-shadow of its own, which would replace that rim or
  // draw a second edge.
  const GLASS_POPUPS = [
    ".ui-popup",
    ".ui-context-menu",
    ".acpmux-menu",
    ".acpmux-slash-menu",
    ".acpmux-mp",
    ".acpmux-access-menu",
    ".acpmux-effort-menu",
    ".acpmux-chat-menu-popover",
    ".acpmux-pr-status",
    ".nt-popover",
    ".acpmux-file-menu-list",
    ".acpmux-needs-you",
    ".acpmux-agents-list",
    ".md-link-popover",
    ".acpmux-omni",
  ];
  test("a glass popup's elevation is the drop alone, under the glass's one rim", () => {
    const elevations = css.flatMap(({ text }) =>
      [...text.matchAll(/(?:^|[;{\s])--glass-elevation\s*:\s*([^;}]+)/g)]
        .filter((match) => {
          const open = text.lastIndexOf("{", match.index);
          const start = Math.max(text.lastIndexOf("}", open), text.lastIndexOf(";", open)) + 1;
          return text.slice(start, open).trim() === ".ui-popup";
        })
        .map((match) => match[1].trim()),
    );
    expect(elevations.length).toBeGreaterThan(0);
    for (const value of elevations)
      expect({ value, hairlines: hairlines(value).length }).toEqual({ value, hairlines: 0 });
  });
  test("no glass popup sets a box-shadow of its own", () => {
    const own = css.flatMap(({ file, text }) =>
      [...text.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
        .filter((rule) => /(?:^|[;\s])box-shadow\s*:/.test(rule[2]))
        .flatMap((rule) =>
          // Top-level selectors (a comma inside :not(...) does not split).
          layers(rule[1])
            .map((selector) => selector.trim().replace(/\s+/g, " "))
            // The popup itself, not a row or control inside it.
            .filter((selector) =>
              GLASS_POPUPS.some((popup) =>
                new RegExp(`${popup.replace(/[.]/g, "\\.")}(?![\\w-])[^\\s>+~()]*$`).test(selector),
              ),
            )
            .map((selector) => `${file}: ${selector}`),
        ),
    );
    expect(own).toEqual([]);
  });
});
