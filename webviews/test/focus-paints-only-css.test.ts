// Focus paints; it never moves anything (Leo, 2026-11-06: "if there's a focus ring, and then I click
// into a chat and I refocus it, like it does a little jump and a hop. There's, like, layout shift
// galore. We need to fix these, but we also need to find the root cause of, like, the generalized
// problem set"). The hop was a selector reacting to focus (`:has(:focus-visible)`) that set margin and
// padding (#39280). The runtime layout-shift budget never saw it: it counts only moves with no input,
// and a focus change always follows a click or a key. So the rule is checked here, in the source:
// a selector that matches only while something is focused sets colors, rims, shadows, outlines and
// the caret, never a property that changes a box's size or place.
// The browser half, for the chat pane: chat-focus-paints-only.test.ts.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src");

function files(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return /^(gallery|prototype|node_modules)$/.test(entry.name) ? [] : files(full);
    return entry.name.endsWith(".css") ? [full] : [];
  });
}

/** A selector that matches only while something is focused, or while the window or pane has focus. */
const FOCUSED = /:focus(?:-visible|-within)?(?![\w-])|\[data-(?:focused|key-window|pane-focused)\b|\.is-focused\b/;

/** Properties that change a box's size or place, or its neighbors'. Border widths count; border colors do not. */
const LAYOUT =
  /^(?:margin|padding|width|height|min-width|min-height|max-width|max-height|top|left|right|bottom|inset|gap|row-gap|column-gap|font|font-size|font-weight|font-family|line-height|letter-spacing|display|position|float|flex|flex-basis|flex-grow|flex-shrink|grid-template(?:-[a-z]+)?|border(?:-(?:top|right|bottom|left))?-width)(?:-[a-z-]+)?$/;

/** `border: 2px solid x` and its sides change width with their length; a color-only value does not. */
function changesLayout(property: string, value: string): boolean {
  if (/^border(?:-(?:top|right|bottom|left))?$/.test(property)) return /\d|\b(?:thin|medium|thick|none)\b/.test(value);
  if (/^(?:border(?:-[a-z]+)*-(?:color|style|radius)|outline.*)$/.test(property)) return false;
  return LAYOUT.test(property);
}

/** Split a selector list at its top-level commas (not the ones inside `:is()`, `:has()`, `:not()`). */
function selectors(list: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < list.length; i++) {
    const c = list[i];
    if (c === "(" || c === "[") depth++;
    else if (c === ")" || c === "]") depth--;
    else if (c === "," && depth === 0) {
      out.push(list.slice(start, i).trim());
      start = i + 1;
    }
  }
  out.push(list.slice(start).trim());
  return out.filter(Boolean);
}

/**
 * Rules that show on focus what hover shows, in the flow, written before this check. Each is a
 * `file: selector` the check reports today; an entry that stops matching fails the test, so this
 * list only shrinks. Never add to it: move the size to the unfocused rule and keep the focused one
 * to paint, or reserve the room (`visibility`, `opacity`) instead of `display`.
 */
const KNOWN: Record<string, string> = {
  "optchat-inspector/styles.css: .term:focus .tip": "the tip is position: absolute in its own rule; a focused term shows it as hover does",
  "pages/server-cards/server/server.css: .sv-device:focus-within .sv-pill": "a focused device card swaps its last-seen text for its pill, as hover does",
  "pages/server-cards/server/server.css: .sv-device:focus-within .sv-device-seen": "the other half of the same swap",
  "pages/home-messages/list/list.css: .hm-draft-close:focus-visible": "the close button is position: absolute in its own rule",
  "agent-session/acpmux/styles.css: .acpmux-fh-name:focus-visible .acpmux-fh-chevron": "a focused file name shows its fold chevron, as hover does",
};

function found(): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const file of files(SRC)) {
    const css = fs.readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
    for (const rule of css.matchAll(/([^{}@;]+)\{([^{}]*)\}/g)) {
      const declarations = rule[2]
        .split(";")
        .map((d) => d.split(":"))
        .filter((d) => d.length >= 2)
        .map(([property, ...value]) => [property.trim().toLowerCase(), value.join(":").trim()] as const);
      // A box taken out of the flow by this same rule moves nothing around it.
      if (declarations.some(([p, v]) => p === "position" && /^(?:absolute|fixed)\b/.test(v))) continue;
      const moved = declarations.filter(([p, v]) => changesLayout(p, v)).map(([p, v]) => `${p}: ${v}`);
      if (moved.length === 0) continue;
      for (const selector of selectors(rule[1])) {
        if (!FOCUSED.test(selector)) continue;
        out.set(`${path.relative(SRC, file)}: ${selector.replace(/\s+/g, " ")}`, moved);
      }
    }
  }
  return out;
}

test("a rule that matches only under focus sets paint, never size or place", () => {
  const hits = found();
  const fresh = [...hits].filter(([key]) => !(key in KNOWN)).map(([key, moved]) => `${key} { ${moved.join("; ")} }`);
  expect(fresh).toEqual([]);
});

test("every known focus-reveal rule still exists (the list only shrinks)", () => {
  const hits = found();
  expect(Object.keys(KNOWN).filter((key) => !hits.has(key))).toEqual([]);
});
