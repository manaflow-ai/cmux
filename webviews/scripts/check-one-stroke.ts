// One stroke from the theme (rule R6 of "one material per surface", design/glass-system.md). Leo,
// 2026-11-21, on the tab hover preview: "like this hover preview of the tabs situation has a black
// border... no bueno. no cohesiveness/theme synchronizing! bad." A floating surface's edge is the theme's
// edge token only: --glass-edge (the card rim, --cmux-card-rim), --ui-popup-edge, the separator tokens,
// or a color-mix of a theme token (color-mix(in srgb, var(--cmux-text) 14%, transparent)). This check
// fails, in the CSS under webviews/src (not tests, galleries, prototypes):
//
//  hard-edge  a floating surface's rule whose edge is a hard-coded color: border, border-color,
//             border-{top,right,bottom,left}(-color), outline(-color), or a box-shadow ring (a part with
//             no blur: `0 0 0 1px …`, `inset 0 1px 0 …`), whose value names black, white, a hex color
//             (#000, #fff, …) or an rgb()/rgba()/hsl()/hsla() literal outside a var() (a var()'s fallback
//             is the token's, so `var(--glass-edge, #fff)` passes). Drop shadows (a part with blur) are
//             elevation, not an edge, and pass.
//  doubled    a floating surface's rule that draws a visible border and an inset ring both (two edges on
//             one surface).
//
// A floating surface's rule: one whose subject (the last compound of a selector in its list) carries a
// class whose last word (after the last `-` or `__`, with a `--modifier` dropped) is one of FLOATING_WORDS:
//   popup, popover, tooltip, card, preview, toast, notice, dialog, sheet, menu, picker, hover, hovercard,
//   peek, flyout, dropdown.
// So `.ui-popup`, `.acpmux-minimap__card`, `.tab-hover-card`, `.x-preview` are; `.x-menu__item` and
// `.ui-popup .row` (a part inside the surface) are not. In-flow cards are not floating (IN_FLOW: classes
// whose card sits in a page's flow, a settings group or a list row) unless the rule also names .ui-glass.
// A rule under @media (forced-colors: active) passes: system colors are the theme there.
//
// A deliberate hard edge says why: `/* one-material-allow: <reason> */` inside the rule or on the line
// before its selector. Their count is pinned (EDGE_ALLOWED_MAX): it can only shrink. The lead wires
// findHardEdges() into check-one-material; test/one-stroke.test.ts runs it alone.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { parseCss, type Rule } from "./check-one-material";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, "../src");

/** How many floating-surface rules may keep a hard edge with `one-material-allow`. Lower it; never raise it. */
export const EDGE_ALLOWED_MAX = 0;

export const FLOATING_WORDS = new Set([
  "popup",
  "popover",
  "tooltip",
  "card",
  "preview",
  "toast",
  "notice",
  "dialog",
  "sheet",
  "menu",
  "picker",
  "hover",
  "hovercard",
  "peek",
  "flyout",
  "dropdown",
]);

/** Card classes that sit in a page's flow, not over it: their edge is a page's, outside this rule. */
export const IN_FLOW: Record<string, string> = {
  "import-card": "Settings > Import's suggestion cards, in the page",
  "feed-card": "the feed page's list rows",
  "apps-card": "the apps page's grid cards",
  "cu-card": "the Chief usage page's cards",
  "text-size-card": "a Settings group",
  "harness-update-card": "a Settings group",
  "density-preview": "Settings' density sample, in the page",
  "chief-pet-preview": "Settings' pet sample, in the page",
  "keys-notice": "a notice line in the keybindings page",
  "pw-notice": "a notice line in the passwords page",
  "bm-notice": "a notice line in the bookmarks page",
  "files-notice": "a notice line in the files page",
  "acpmux-permission-card": "a permission request in the transcript",
  "acpmux-open-app-card": "an open-app card in the transcript",
  "comment-card": "a review comment in the diff",
  "cmux-comment-card": "a comment in the Markdown viewer",
  "run-board-preview": "a run's preview tile on the run board",
  "timeline-preview": "a run's preview on the timeline",
  "cloud-file-preview": "the cloud page's file pane",
  card: "the optchat inspector's panels (a debug page)",
};

const SKIP_FILE = /\.(test|gallery)\.[cm]?[jt]sx?$|\.gallery\.css$/;
const SKIP_DIR = new Set(["node_modules", "prototypes", "prototype", "gallery"]);
const EDGE_PROPS =
  /^(border|border-color|border-(top|right|bottom|left)(-color)?|border-(block|inline)(-(start|end))?(-color)?|outline|outline-color)$/;
const HARD = /(^|[^\w-])(black|white)(?![\w-])|#[0-9a-f]{3,8}\b|\b(rgba?|hsla?)\(/i;

/** `value` with every var(...) (and its fallback) removed: what is left is the declaration's own colors. */
export function withoutVars(value: string): string {
  let out = "";
  let i = 0;
  while (i < value.length) {
    if (value.startsWith("var(", i)) {
      let depth = 0;
      let j = i + 3;
      for (; j < value.length; j++) {
        if (value[j] === "(") depth++;
        else if (value[j] === ")" && --depth === 0) break;
      }
      i = j + 1;
      out += " ";
      continue;
    }
    out += value[i];
    i++;
  }
  return out;
}

/** Splits at commas outside parentheses. */
function topLevel(value: string, sep = ","): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < value.length; i++) {
    const ch = value[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if (ch === sep && depth === 0) {
      parts.push(value.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(value.slice(start));
  return parts.map((part) => part.trim()).filter(Boolean);
}

/** The lengths of one box-shadow part, in order (offset x, offset y, blur, spread), as numbers; a var() or
 *  calc() that names a length (a hairline, a width) counts as a non-zero length. */
function lengths(part: string): number[] {
  const out: number[] = [];
  for (const token of topLevel(part, " ")) {
    if (/^-?(\d*\.?\d+)(px|rem|em)?$/.test(token)) out.push(Number.parseFloat(token));
    else if (token.startsWith("calc(") || /^var\(--[\w-]*(hairline|width|spread|blur|size|line)[\w-]*/.test(token))
      out.push(1);
  }
  return out;
}

/** A box-shadow part that draws a crisp line (a ring or a hairline): no blur, and some offset or spread. */
function ring(part: string): boolean {
  if (/^none$/i.test(part.trim())) return false;
  const lens = lengths(part);
  if (lens.length < 2) return false;
  const [x = 0, y = 0, blur = 0, spread = 0] = lens;
  return blur === 0 && (x !== 0 || y !== 0 || spread !== 0);
}

function hard(value: string): boolean {
  return HARD.test(withoutVars(value));
}

function invisible(value: string): boolean {
  return (
    /^(none|0|0px|hidden|transparent|initial|unset|inherit|revert)$/i.test(value.trim()) ||
    /\btransparent\b/.test(value)
  );
}

/** Whether a class names a floating surface (see the header). */
export function floatingClass(name: string): boolean {
  const base = name.replace(/--[\w-]*$/, "");
  const word = base.split(/__|-/).at(-1)?.toLowerCase() ?? "";
  return FLOATING_WORDS.has(word) && !(name in IN_FLOW);
}

/** Whether the rule's subject (the last compound of any selector in its list) is a floating surface. */
export function floatingRule(rule: Pick<Rule, "selector">): boolean {
  return topLevel(rule.selector).some((selector) => {
    const subject = selector.split(/\s*[>+~]\s*|\s+/).at(-1) ?? "";
    const classes = [...subject.replace(/:[\w-]+\([^)]*\)/g, "").matchAll(/\.([\w-]+)/g)].map((match) => match[1]!);
    if (classes.some((name) => name in IN_FLOW) && !classes.includes("ui-glass")) return false;
    return classes.some((name) => floatingClass(name));
  });
}

/** The R6 findings for one stylesheet: `file:line: [rule] selector …` for each floating rule that fails. */
export function edgeFindings(css: string, file: string): string[] {
  return edgeRules(css, file).errors;
}

function edgeRules(css: string, file: string): { errors: string[]; allowed: string[] } {
  const errors: string[] = [];
  const allowed: string[] = [];
  for (const rule of parseCss(css)) {
    if (!floatingRule(rule)) continue;
    if (rule.context.some((parent) => /forced-colors\s*:\s*active/.test(parent))) continue;
    const where = `${file}:${rule.line}: ${rule.selector}`;
    const found: string[] = [];
    for (const decl of rule.decls) {
      if (EDGE_PROPS.test(decl.prop) && hard(decl.value) && !invisible(decl.value))
        found.push(`[hard-edge] ${decl.prop}: ${decl.value}`);
      if (decl.prop === "box-shadow") {
        const hardRing = topLevel(decl.value).find((part) => ring(part) && hard(part));
        if (hardRing) found.push(`[hard-edge] box-shadow ring ${hardRing}`);
      }
    }
    const border = rule.decls.find(
      (decl) => /^border(-width)?$/.test(decl.prop) && !invisible(decl.value) && !/^0(px)?\b/.test(decl.value),
    );
    const insetRing = rule.decls
      .filter((decl) => decl.prop === "box-shadow")
      .flatMap((decl) => topLevel(decl.value))
      .find((part) => /\binset\b/.test(part) && ring(part) && !/\btransparent\b/.test(part));
    if (border && insetRing) found.push(`[doubled] border ${border.value} and inset ring ${insetRing}`);
    if (found.length === 0) continue;
    if (rule.allowed) {
      allowed.push(where);
      continue;
    }
    for (const finding of found)
      errors.push(
        `${where} ${finding}: a floating surface's edge is the theme's (--glass-edge, --ui-popup-edge, a ` +
          "separator token or a color-mix of one), drawn once; or say why: /* one-material-allow: <reason> */",
      );
  }
  return { errors, allowed };
}

function* walk(dir: string): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIR.has(entry.name)) yield* walk(full);
    } else if (entry.name.endsWith(".css") && !SKIP_FILE.test(entry.name)) yield full;
  }
}

/** R6 over every stylesheet under `root` (webviews/src by default), with the allowed-count pin. */
export function findHardEdges(root: string = SRC): { errors: string[]; allowed: string[] } {
  const errors: string[] = [];
  const allowed: string[] = [];
  for (const path of walk(root)) {
    const file = relative(root, path);
    const result = edgeRules(readFileSync(path, "utf8"), file);
    errors.push(...result.errors);
    allowed.push(...result.allowed);
  }
  if (allowed.length > EDGE_ALLOWED_MAX)
    errors.push(
      `[hard-edge] ${allowed.length} floating rules keep a hard edge with one-material-allow, more than ` +
        `EDGE_ALLOWED_MAX (${EDGE_ALLOWED_MAX}): draw the theme's edge instead`,
    );
  else if (root === SRC && allowed.length < EDGE_ALLOWED_MAX)
    errors.push(
      `[hard-edge] stale pin: ${allowed.length} allowed hard edges, below EDGE_ALLOWED_MAX (${EDGE_ALLOWED_MAX}); lower it`,
    );
  return { errors, allowed };
}

if (import.meta.main) {
  const { errors, allowed } = findHardEdges();
  for (const line of allowed) console.log(`allowed: ${line}`);
  for (const line of errors) console.error(line);
  console.log(`check-one-stroke: ${errors.length} errors, ${allowed.length} allowed`);
  process.exit(errors.length > 0 ? 1 : 0);
}
