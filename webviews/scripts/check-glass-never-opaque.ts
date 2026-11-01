// Glass is never opaque (Leo 2026-10-20: "we want a lot of glass... I hate opaque"). A surface that
// blurs what is behind it (`backdrop-filter`), a class named glass, or a glass token (a custom
// property named `--*glass*`) must let that backdrop show: its fill is never a solid color. An opaque fill under a
// blur hides the blur and reads as a flat card. Reduce Transparency is the one place glass turns
// solid, so rules under `@media (prefers-reduced-transparency: reduce)` or
// `[data-reduce-transparency]` are not checked. A surface that is solid on purpose (a menu, the
// popup card) sets no blur (`backdrop-filter: none`) and is not glass. The Swift side is the
// ast-grep rule no-opaque-glass. test/glass-never-opaque.test.ts runs this in the webviews test lane;
// `bun scripts/check-glass-never-opaque.ts` runs it alone.
//
// Only fills this test can prove opaque fail it: a literal color with no alpha, `Canvas`, a token
// whose every definition is opaque (or a host token named `solid`/`popup-surface`, the solid
// surfaces WebTheme.swift injects), or a `color-mix` of two opaque colors. Anything it cannot
// resolve passes. A rule that must stay solid under its blur says why on the line before its
// background: `/* glass-opaque-allow: <reason> */`.
//
// Tooltips and hover cards are glass (Leo 2026-10-21: "WHERE IS THE GLASS EVERYWHERE, all these
// hover tooltips and hover previews"). A rule whose selector names a tooltip or a hover card counts
// as glass even without a blur, so `backdrop-filter: none` never makes one a legitimately solid
// card, and `findSolidTooltipMarkup` fails a tooltip class list in the page code (`ui-tooltip`,
// `ui-title-tooltip`) that does not carry `ui-glass`.
// Named floating surfaces are glass too, even when their old markup and stylesheet set neither
// ui-glass nor a blur. The classic New Tab omnibar used to escape both checks that way.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../src");
const ALLOW = /glass-opaque-allow:\s*\S/;
// Reduce Transparency contexts; `not (...)` and `:not([...])` are the glass side, so they stay checked.
const REDUCE_MEDIA = /(?<!not\s*)\(\s*prefers-reduced-transparency\s*:\s*reduce\s*\)/;
const REDUCE_ATTR = /(?<!:not\(\s*)\[data-reduce-transparency\]/;
// Host tokens (WebTheme.swift) the CSS never defines but documents as solid.
const HOST_SOLID = /^--cmux-(?:.*solid.*|popup-surface)$/;
// A tooltip or hover card: `.ui-tooltip`, `.ui-title-tooltip`, `.ui-hint`, `.ui-card`, `.cu-tooltip`,
// `.x-hover-card`, `[role="tooltip"]`.
const TOOLTIP = /tooltip|\.ui-hint\b|\.ui-card\b|hover-?card|\[role=["']?tooltip/i;
// The History page menu (pages/shared/PageMenu.tsx) drew the solid popup surface under a border
// (Leo 2026-10-21: "STOP DOING SOLID. WE HAVE GLASS, SO JUST USE GLASS.").
const REQUIRED_GLASS_CLASSES = new Set(["acpmux-omni", "page-menu"]);
// Tooltip rules whose solid fill never paints, keyed `file selector`, with the reason. Prefer an
// inline `glass-opaque-allow`; this list holds only fills in a file another open pull request is
// editing, and each entry goes when that file is free.
const TOOLTIP_FILL_OVERRIDDEN = new Map<string, string>([
  [
    "pages/shared/desktop.css .ui-card",
    "every AnchoredCard also carries .ui-glass, and glass.css's tooltip rule paints over this fill (desktop.css is in #23066)",
  ],
]);
const NAMED_TRANSLUCENT = new Set(["transparent"]);
const NAMED_UNKNOWN = new Set(["currentcolor", "inherit", "initial", "unset", "revert", "none"]);

export type Kind = "opaque" | "translucent" | "unknown";
export interface Block {
  file: string;
  line: number;
  selector: string;
  context: string[];
  decls: { prop: string; value: string; line: number; allowed: boolean }[];
}

function cssFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return cssFiles(path);
    return entry.name.endsWith(".css") ? [path] : [];
  });
}

// Blocks with their declarations and enclosing preludes (at-rules, nested selectors). Comments are
// kept long enough to read an allowance, then dropped.
function parse(file: string, text: string): Block[] {
  const blocks: Block[] = [];
  const stack: { prelude: string; block: Block }[] = [];
  let buf = "";
  let line = 1;
  let pendingAllow = false;
  let i = 0;
  const current = () => stack.at(-1)?.block;
  const flushDecl = () => {
    const decl = buf.trim();
    buf = "";
    const block = current();
    const colon = decl.indexOf(":");
    if (!block || colon <= 0) return;
    block.decls.push({
      prop: decl.slice(0, colon).trim().toLowerCase(),
      value: decl
        .slice(colon + 1)
        .trim()
        .replace(/\s*!important$/, ""),
      line,
      allowed: pendingAllow,
    });
    pendingAllow = false;
  };
  while (i < text.length) {
    const ch = text[i];
    if (ch === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      const comment = text.slice(i, end < 0 ? text.length : end + 2);
      if (ALLOW.test(comment)) pendingAllow = true;
      line += comment.split("\n").length - 1;
      i += comment.length;
      continue;
    }
    if (ch === '"' || ch === "'") {
      const end = text.indexOf(ch, i + 1);
      buf += text.slice(i, end < 0 ? text.length : end + 1);
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (ch === "\n") line++;
    if (ch === "{") {
      const prelude = buf.trim().replace(/\s+/g, " ");
      buf = "";
      const block: Block = {
        file,
        line,
        selector: prelude,
        context: stack.map((s) => s.prelude),
        decls: [],
      };
      blocks.push(block);
      stack.push({ prelude, block });
    } else if (ch === "}") {
      flushDecl();
      stack.pop();
    } else if (ch === ";") {
      flushDecl();
    } else {
      buf += ch;
    }
    i++;
  }
  return blocks;
}

function splitArgs(inner: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < inner.length; i++) {
    if (inner[i] === "(") depth++;
    else if (inner[i] === ")") depth--;
    else if (inner[i] === "," && depth === 0) {
      out.push(inner.slice(start, i).trim());
      start = i + 1;
    }
  }
  out.push(inner.slice(start).trim());
  return out;
}

// `name(args)` spanning the whole value, else null.
function call(value: string): { name: string; args: string[] } | null {
  const m = /^([\w-]+)\(([\s\S]*)\)$/.exec(value.trim());
  if (!m) return null;
  let depth = 0;
  const inner = m[2] ?? "";
  for (let i = 0; i < inner.length; i++) {
    if (inner[i] === "(") depth++;
    else if (inner[i] === ")" && --depth < 0) return null; // `a(x) b(y)`: not one call
  }
  return { name: (m[1] ?? "").toLowerCase(), args: splitArgs(inner) };
}

let tokens = new Map<string, string[]>();

function classifyToken(name: string, fallback: string | undefined, seen: Set<string>): Kind {
  const defs = tokens.get(name);
  if (!defs) {
    if (HOST_SOLID.test(name)) return "opaque";
    return fallback === undefined ? "unknown" : classify(fallback, seen);
  }
  if (seen.has(name)) return "unknown";
  const next = new Set(seen).add(name);
  const kinds = defs.map((d) => classify(d, next));
  if (kinds.includes("translucent")) return "translucent";
  if (kinds.every((k) => k === "opaque")) return "opaque";
  return "unknown";
}

function alphaOf(text: string): number | null {
  const slash = /\/\s*([\d.]+)(%?)\s*$/.exec(text);
  if (slash) return Number(slash[1]) / (slash[2] ? 100 : 1);
  return null;
}

function classify(raw: string, seen = new Set<string>()): Kind {
  const value = raw.trim();
  const lower = value.toLowerCase();
  if (NAMED_TRANSLUCENT.has(lower)) return "translucent";
  if (NAMED_UNKNOWN.has(lower)) return "unknown";
  if (/^#[0-9a-f]{3}$|^#[0-9a-f]{6}$/i.test(value)) return "opaque";
  if (/^#[0-9a-f]{4}$/i.test(value)) return /f$/i.test(value) ? "opaque" : "translucent";
  if (/^#[0-9a-f]{8}$/i.test(value)) return /ff$/i.test(value) ? "opaque" : "translucent";
  if (/^[a-z]+$/i.test(value)) return "opaque"; // a named color or system color (Canvas)
  const fn = call(value);
  if (!fn) return "unknown"; // gradients, images, layered backgrounds
  if (fn.name === "var") {
    const [name = "", ...rest] = fn.args;
    return classifyToken(name, rest.length ? rest.join(",") : undefined, seen);
  }
  if (fn.name === "light-dark") {
    const kinds = fn.args.map((a) => classify(a, seen));
    if (kinds.includes("opaque")) return "opaque";
    return kinds.includes("translucent") ? "translucent" : "unknown";
  }
  if (/^(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)$/.test(fn.name)) {
    const legacy = fn.args.length === 4 ? Number.parseFloat(fn.args[3] ?? "") : null;
    const alpha = legacy !== null ? legacy / ((fn.args[3] ?? "").endsWith("%") ? 100 : 1) : alphaOf(fn.args.join(" "));
    if (alpha === null) return value.includes("var(") ? "unknown" : "opaque";
    return Number.isNaN(alpha) ? "unknown" : alpha >= 1 ? "opaque" : "translucent";
  }
  if (fn.name === "color-mix") {
    const parts = fn.args.slice(1).map((arg) => {
      const pct = /\s(\d+(?:\.\d+)?)%\s*$|^(\d+(?:\.\d+)?)%\s/.exec(arg);
      const color = arg.replace(/\s\d+(?:\.\d+)?%\s*$|^\d+(?:\.\d+)?%\s/, "").trim();
      const share = pct ? Number(pct[1] ?? pct[2]) : null;
      return { color, share };
    });
    if (parts.length !== 2) return "unknown";
    const [a, b] = parts as [(typeof parts)[0], (typeof parts)[0]];
    const shareA = a.share ?? (b.share !== null ? 100 - b.share : 50);
    const shareB = b.share ?? 100 - shareA;
    const ka = shareA > 0 ? classify(a.color, seen) : "opaque";
    const kb = shareB > 0 ? classify(b.color, seen) : "opaque";
    if (ka === "translucent" || kb === "translucent") return "translucent";
    return ka === "opaque" && kb === "opaque" ? "opaque" : "unknown";
  }
  return "unknown";
}

function inReduce(block: Block): boolean {
  return [...block.context, block.selector].some((p) => REDUCE_MEDIA.test(p) || REDUCE_ATTR.test(p));
}

function blurs(block: Block): boolean {
  return block.decls.some(
    (d) => /^(-webkit-)?backdrop-filter$/.test(d.prop) && !/^(none|initial|unset)$/i.test(d.value),
  );
}

/** The selector's subject, not a row or control inside a named glass surface. Functional pseudo
 * selectors and attribute values do not contribute class names or descendant combinators. */
export function targetsRequiredGlass(selector: string): boolean {
  return splitArgs(selector).some((part) => {
    let depth = 0;
    let subject = "";
    for (const ch of part) {
      if (ch === "(" || ch === "[") {
        depth++;
      } else if (ch === ")" || ch === "]") {
        depth--;
      } else if (depth === 0) {
        if (/[\s>+~]/.test(ch)) subject = "";
        else subject += ch;
      }
    }
    return [...subject.matchAll(/\.([\w-]+)/g)].some((match) => REQUIRED_GLASS_CLASSES.has(match[1] ?? ""));
  });
}

/** Every rule under srcDir outside Reduce Transparency; loads the tokens they define for fillKind. */
export function glassContextRules(srcDir: string = SRC): Block[] {
  const parsed = cssFiles(srcDir).flatMap((file) => parse(relative(srcDir, file), readFileSync(file, "utf8")));
  const rules = parsed.filter((block) => !inReduce(block));
  tokens = new Map();
  for (const block of rules) {
    for (const d of block.decls) {
      if (!d.prop.startsWith("--")) continue;
      tokens.set(d.prop, [...(tokens.get(d.prop) ?? []), d.value]);
    }
  }
  return rules;
}

/** What a fill provably is, resolving tokens from the last glassContextRules() call. */
export function fillKind(value: string): Kind {
  return classify(value);
}

/** Every glass fill under src/ that is opaque, as `file:line: selector { prop: value }`. */
export function findOpaqueGlass(srcDir: string = SRC): string[] {
  const found: string[] = [];
  for (const block of glassContextRules(srcDir)) {
    // A required surface stays glass even if its old markup has no ui-glass and its CSS no blur.
    const tooltip = TOOLTIP.test(block.selector);
    const glass =
      blurs(block) || /\.[\w-]*glass[\w-]*/i.test(block.selector) || tooltip || targetsRequiredGlass(block.selector);
    const overridden = tooltip && TOOLTIP_FILL_OVERRIDDEN.has(`${block.file} ${block.selector}`);
    for (const d of block.decls) {
      if (d.allowed || overridden) continue;
      const fill = glass && (d.prop === "background" || d.prop === "background-color");
      const glassToken = d.prop.startsWith("--") && /glass/.test(d.prop);
      if (!fill && !glassToken) continue;
      // A glass share (`--x-glass: 60%`) is the fill's share in a color-mix: 100% is solid.
      const share = /^(\d+(?:\.\d+)?)%$/.exec(d.value);
      const opaque = share ? Number(share[1]) >= 100 : classify(d.value) === "opaque";
      if (opaque) found.push(`${block.file}:${d.line}: ${block.selector} { ${d.prop}: ${d.value} }`);
    }
  }
  return found;
}

// A page the app floats as a menu, picker or popover over the window (Swift
// `PageEngineOptions(requiresWebKit: .transparentOverlay)`): the host draws Glass.makeOverlayPanel
// behind the page, so the page's own root (html, body, :root, #root) must let it show. The shared
// page base paints html with the host's `--cmux-surface-background`, which is the opaque theme
// surface over an opaque window, so a popup document paints its html transparent itself.
const ROOT_SUFFIX = /^(?:\[[^\]]*\]|:[\w-]+(?:\([^)]*\))?|[.#][\w-]+)*$/;
const ROOT_COMPOUND = new RegExp(`^(?:html|body|:root|#root)${ROOT_SUFFIX.source.slice(1)}`);

// `:is(a, b)`, `:where(...)` or `:matches(...)` opening a compound: its list and what follows it.
function leadingList(compound: string): { list: string; rest: string } | null {
  const open = /^:(?:is|where|matches)\(/.exec(compound);
  if (!open) return null;
  let depth = 1;
  for (let i = open[0].length; i < compound.length; i++) {
    if (compound[i] === "(") depth++;
    else if (compound[i] === ")" && --depth === 0)
      return { list: compound.slice(open[0].length, i), rest: compound.slice(i + 1) };
  }
  return null;
}

// Split at separators outside (...) and [...], so :is(a, b) and [x="a b"] stay whole.
function splitTopLevel(text: string, separator: RegExp): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === "(" || char === "[") depth++;
    else if ((char === ")" || char === "]") && depth > 0) depth--;
    else if (depth === 0 && separator.test(char)) {
      parts.push(text.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(text.slice(start));
  return parts;
}

// "html" when one selector of the list is the document's root element alone, "root" when one ends
// in html, body, :root or #root, else null.
function rootTarget(selector: string): "html" | "root" | null {
  let target: "html" | "root" | null = null;
  for (const part of splitTopLevel(selector, /,/)) {
    const compounds = splitTopLevel(part.trim(), /[\s>+~]/).filter(Boolean);
    const last = compounds.at(-1) ?? "";
    // :is(body, #root) and :where(...) match what their own list matches; classes, attributes and
    // pseudo-classes after the list narrow the same element.
    const listed = leadingList(last);
    if (listed) {
      const inner = ROOT_SUFFIX.test(listed.rest) ? rootTarget(listed.list) : null;
      if (inner === "html" && compounds.length === 1) return "html";
      if (inner) target = "root";
      continue;
    }
    if (!ROOT_COMPOUND.test(last)) continue;
    if (compounds.length === 1 && /^(?:html|:root)/.test(last)) return "html";
    target = "root";
  }
  return target;
}

/** A root background value that leaves no fill: `none` (no image, the color's initial transparent)
 * on the shorthand, and the CSS-wide keywords that reset to it (background is not inherited). */
function clearsFill(prop: string, value: string): boolean {
  const lower = value.trim().toLowerCase();
  if (lower === "initial" || lower === "unset") return true;
  return prop === "background" && lower === "none";
}

/**
 * Every popup page document (`pages`, paths under src/: a stylesheet, or all of one page's) whose
 * root paints an opaque fill, or whose html never paints itself transparent, as
 * `file:line: selector { prop: value }` or `file: …` (a page's first stylesheet).
 */
export function findOpaquePopupPageRoots(pages: (string | string[])[], srcDir: string = SRC): string[] {
  const all = cssFiles(srcDir).flatMap((file) => parse(relative(srcDir, file), readFileSync(file, "utf8")));
  tokens = new Map();
  for (const block of all) {
    if (inReduce(block)) continue;
    for (const d of block.decls) {
      if (d.prop.startsWith("--")) tokens.set(d.prop, [...(tokens.get(d.prop) ?? []), d.value]);
    }
  }
  const found: string[] = [];
  for (const page of pages) {
    const files = typeof page === "string" ? [page] : page;
    let clearHtml = false;
    for (const file of files) {
      const blocks = all.filter((block) => block.file === file && !inReduce(block));
      if (blocks.length === 0) found.push(`${file}: no such stylesheet under src/`);
      for (const block of blocks) {
        const target = rootTarget(block.selector);
        if (!target) continue;
        for (const d of block.decls) {
          if (d.prop !== "background" && d.prop !== "background-color") continue;
          const kind = classify(d.value);
          if (kind === "opaque" && !d.allowed)
            found.push(`${file}:${d.line}: ${block.selector} { ${d.prop}: ${d.value} }`);
          if (target === "html" && (kind === "translucent" || clearsFill(d.prop, d.value))) clearHtml = true;
        }
      }
    }
    if (!clearHtml && files.length > 0 && !found.includes(`${files[0]}: no such stylesheet under src/`))
      found.push(
        `${files[0]}: the popup document never paints html transparent (the page base paints the host's surface)`,
      );
  }
  return found;
}

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "gallery" ? [] : sourceFiles(path);
    return /\.tsx?$/.test(entry.name) && !/\.(test|gallery)\.tsx?$/.test(entry.name) ? [path] : [];
  });
}

/** Every tooltip class list in the page code that is not glass, as `file:line: "classes"`. A
 * tooltip element is `ui-tooltip` (ui/Tooltip.tsx, AnchoredCard) or `ui-title-tooltip`
 * (ui/titleTooltips.ts); it carries `ui-glass` with it. */
export function findSolidTooltipMarkup(srcDir: string = SRC): string[] {
  const found: string[] = [];
  for (const file of sourceFiles(srcDir)) {
    const text = readFileSync(file, "utf8");
    for (const match of text.matchAll(/["`]([^"`\n]*)["`]/g)) {
      const names = (match[1] ?? "").split(/\s+/);
      if (!names.some((name) => name === "ui-tooltip" || name === "ui-title-tooltip")) continue;
      if (names.includes("ui-glass")) continue;
      const line = text.slice(0, match.index).split("\n").length;
      found.push(`${relative(srcDir, file)}:${line}: ${match[0]}`);
    }
  }
  return found;
}

/** A named floating surface's className literal must carry ui-glass itself. Only className values
 * count: an id, a query selector or a child class containing the surface's name is not its markup. */
export function findMissingGlassMarkup(srcDir: string = SRC): string[] {
  const found: string[] = [];
  for (const file of sourceFiles(srcDir)) {
    const text = readFileSync(file, "utf8");
    for (const match of text.matchAll(/\bclassName\s*=\s*(?:\{\s*)?(["`])([^"`\n]*)\1/g)) {
      const classes = match[2] ?? "";
      const names = classes.split(/\s+/);
      if (!names.some((name) => REQUIRED_GLASS_CLASSES.has(name)) || names.includes("ui-glass")) continue;
      const line = text.slice(0, match.index).split("\n").length;
      found.push(`${relative(srcDir, file)}:${line}: ${JSON.stringify(classes)}`);
    }
  }
  return found;
}

// Overlay surfaces are glass, never opaque (Leo: "Glass, never opaque"; "I don't like the
// non-glassness"). A popover, popup, menu, dropdown, toast, sheet, dialog, card, tooltip, hover card,
// picker, palette or bubble (a rule whose subject's class ends in one of those words: `.ui-popup`,
// `.page-menu`, `.acpmux-summary-card`, `.lg-sheet`; not a part of one: `.ui-menu-item`) and every
// glass rule never paint a fill that covers 90% or more of what is behind them, outside Reduce
// Transparency: an opaque fill, a near-opaque one (`color-mix(... 94%, transparent)`, cmux#22670's
// Updated card) or a layered stack that adds up to it. Legibility comes from the blur, tint and
// contrast inside the glass. A surface that must stay solid says why: `/* glass-opaque-allow:
// <reason> */` on the line before its fill, or an OVERLAY_ALLOWED entry. A gallery stage
// (`*.gallery.css`, the gallery/ shell) and the unshipped prototypes/ are not product surfaces.
const OVERLAY_ROLE =
  /^(?:popover|popup|menu|dropdown|toast|sheet|dialog|card|tooltip|hovercard|picker|palette|bubble)s?$/i;
// The least share a fill may leave of what is behind it: at 90% or more a fill reads as solid.
export const NEAR_OPAQUE = 0.9;
// Host tokens (WebTheme.swift) the CSS never defines, by the least alpha they paint at.
const HOST_ALPHA = new Map<string, number>([
  // CardMaterial: the popup surface at no less than 90% (glass.cardOpacity), mostly opaque.
  ["--cmux-card-tint", 0.9],
]);
// Overlay rules that stay solid on purpose, keyed `file selector`, with the reason (the PR that added
// an entry lists it; design/overlay-surfaces.md in leo-workspace holds the policy).
export const OVERLAY_ALLOWED = new Map<string, string>([
  [
    "optchat-inspector/styles.css .card",
    "the OptChat developer inspector's in-page report cards, on its own page, not floating over anything",
  ],
  [
    "pages/chief-views/styles.css .cv-card",
    "a Chief view's in-page content card, on its own page, not floating (Chief area: its owners' call)",
  ],
  [
    "agent-session/acpmux/conversation/conversation.css .acpmux-image-viewer",
    "the full-pane image viewer: a blurred lightbox that sets the image apart from the chat, not a floating card",
  ],
  [
    "agent-session/acpmux/summary/summary.css .acpmux-chat-gallery",
    "the chat's full-pane image gallery: the image viewer's blurred lightbox, not a floating card",
  ],
]);
// Overlays that are solid today and are being made glass, keyed `file selector`, with what fixes it.
// Each fails as stale once its fill is glass, so the entry goes with the fix.
export const OVERLAY_PENDING = new Map<string, string>([
  ["pages/settings/styles.css .menus-move-picker", "Settings' Menus move picker paints the solid popup surface"],
  ["pages/shared/pageBase.css .page-menu", "the shared page menu paints the solid popup surface, not .ui-glass"],
  ["pages/cloud/styles.css .cloud-create-sheet", "Cloud's create sheet paints the elevated surface"],
  ["pages/home-channels/ledger.css .lg-sheet", "the ledger's side sheet paints its solid surface"],
  [
    "pages/home-channels/ledger.css .lg-palette.ui-dialog, .lg-palette",
    "the ledger's palette dialog paints the solid popup surface",
  ],
  [
    "pages/home-channels/ledger.css .lg-form.ui-dialog, .lg-form",
    "the ledger's form dialog paints the solid popup surface",
  ],
  ["pages/markdown/styles.css .cmux-comment-card", "the Markdown viewer's comment card paints the elevated surface"],
  ["ui/ui.css .ui-sheet", "the shared sheet paints --ui-surface, not the glass"],
  ["ui/findPill.css .find-pill", "the find pill paints the card material (--cmux-card-tint, at least 90%)"],
  [
    "pages/markdown/styles.css .md-link-bubble",
    "the Markdown link editor popover paints --cmux-md-popover-background (the solid popup surface) over its glass",
  ],
]);

function blockSubjects(selector: string): string[] {
  return splitArgs(selector).map((part) => {
    let depth = 0;
    let subject = "";
    for (const ch of part) {
      if (ch === "(" || ch === "[") depth++;
      else if (ch === ")" || ch === "]") depth--;
      if (depth === 0 && /[\s>+~]/.test(ch)) subject = "";
      else subject += ch;
    }
    return subject;
  });
}

/** The rule's subject is an overlay surface: one of its classes (BEM modifier dropped) ends in a role. */
export function targetsOverlay(selector: string): boolean {
  return blockSubjects(selector).some((subject) =>
    [...subject.replace(/\[[^\]]*\]|\([^)]*\)/g, "").matchAll(/\.([\w-]+)/g)].some((match) => {
      const name = (match[1] ?? "").replace(/--[\w-]*$/, "");
      return OVERLAY_ROLE.test(name.split(/__|-|_/).at(-1) ?? "");
    }),
  );
}

/** The least alpha a fill provably paints at, or null when this cannot tell. A layered background
 * paints what its layers add up to. */
export function fillAlpha(raw: string, seen = new Set<string>()): number | null {
  const value = raw.trim();
  const lower = value.toLowerCase();
  if (lower === "transparent" || lower === "none") return 0;
  if (NAMED_UNKNOWN.has(lower)) return null;
  if (!call(value) && splitArgs(value).length > 1) {
    let clear = 1;
    let known = false;
    for (const layer of splitArgs(value)) {
      const alpha = fillAlpha(layer, seen);
      if (alpha === null) continue;
      known = true;
      clear *= 1 - alpha;
    }
    return known ? 1 - clear : null;
  }
  const fn = call(value);
  // A literal (a hex or named color) classify can call opaque. A function is measured below: classify
  // calls a mix of two opaque colors opaque whatever its shares, also through a token, and shares
  // under 100% leave the rest transparent.
  if (!fn && classify(value, seen) === "opaque") return 1;
  if (/^#[0-9a-f]{4}$/i.test(value)) return Number.parseInt(value.slice(4), 16) / 15;
  if (/^#[0-9a-f]{8}$/i.test(value)) return Number.parseInt(value.slice(7), 16) / 255;
  if (!fn) return null;
  if (fn.name === "var") {
    const [name = "", ...rest] = fn.args;
    const defs = tokens.get(name);
    if (!defs) {
      const host = HOST_ALPHA.get(name) ?? (HOST_SOLID.test(name) ? 1 : undefined);
      if (host !== undefined) return host;
      return rest.length ? fillAlpha(rest.join(","), seen) : null;
    }
    if (seen.has(name)) return null;
    const next = new Set(seen).add(name);
    const alphas = defs.map((def) => fillAlpha(def, next));
    return alphas.some((alpha) => alpha === null) ? null : Math.min(...(alphas as number[]));
  }
  if (fn.name === "light-dark") {
    const alphas = fn.args.map((arg) => fillAlpha(arg, seen));
    return alphas.some((alpha) => alpha === null) ? null : Math.min(...(alphas as number[]));
  }
  if (/^(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)$/.test(fn.name)) {
    const legacy = fn.args.length === 4 ? Number.parseFloat(fn.args[3] ?? "") : null;
    const alpha = legacy !== null ? legacy / ((fn.args[3] ?? "").endsWith("%") ? 100 : 1) : alphaOf(fn.args.join(" "));
    // No alpha at all: opaque, unless a token may carry one. An alpha this cannot read (`/ calc(...)`)
    // is unknown, not opaque.
    if (alpha === null) return value.includes("var(") || value.includes("/") || fn.args.length > 3 ? null : 1;
    return Number.isNaN(alpha) ? null : alpha;
  }
  if (fn.name === "color-mix") {
    const parts = fn.args.slice(1).map((arg) => {
      const pct = /\s(\d+(?:\.\d+)?)%\s*$|^(\d+(?:\.\d+)?)%\s/.exec(arg);
      const color = arg.replace(/\s\d+(?:\.\d+)?%\s*$|^\d+(?:\.\d+)?%\s/, "").trim();
      return { color, share: pct ? Number(pct[1] ?? pct[2]) : null };
    });
    if (parts.length !== 2) return null;
    const [a, b] = parts as [(typeof parts)[0], (typeof parts)[0]];
    const shareA = a.share ?? (b.share !== null ? 100 - b.share : 50);
    const shareB = b.share ?? (a.share !== null ? 100 - a.share : 50);
    // Shares over 100% are scaled down to it; under 100%, the rest is transparent.
    const scale = shareA + shareB > 100 ? 100 / (shareA + shareB) : 1;
    const alphaA = shareA > 0 ? fillAlpha(a.color, seen) : 0;
    const alphaB = shareB > 0 ? fillAlpha(b.color, seen) : 0;
    if (alphaA === null || alphaB === null) return null;
    return ((shareA * alphaA + shareB * alphaB) * scale) / 100;
  }
  return null;
}

/** Every overlay surface or glass rule under srcDir whose fill covers NEAR_OPAQUE or more outside
 * Reduce Transparency, as `file:line: selector { prop: value }`, then every OVERLAY_ALLOWED or
 * OVERLAY_PENDING entry nothing matched (`stale: …`). A glass rule's provably opaque fill is
 * findOpaqueGlass's, so it is not repeated here. */
export function findOpaqueOverlays(srcDir: string = SRC): string[] {
  const found: string[] = [];
  const used = new Set<string>();
  for (const block of glassContextRules(srcDir)) {
    if (block.file.endsWith(".gallery.css") || /^(?:gallery|prototypes)\//.test(block.file)) continue;
    const overlay = targetsOverlay(block.selector);
    const tooltip = TOOLTIP.test(block.selector);
    const glass =
      blurs(block) || /\.[\w-]*glass[\w-]*/i.test(block.selector) || tooltip || targetsRequiredGlass(block.selector);
    if (!overlay && !glass) continue;
    const key = `${block.file} ${block.selector}`;
    if (tooltip && TOOLTIP_FILL_OVERRIDDEN.has(key)) continue;
    for (const d of block.decls) {
      if (d.allowed || (d.prop !== "background" && d.prop !== "background-color")) continue;
      if (glass && classify(d.value) === "opaque") continue;
      const alpha = fillAlpha(d.value);
      if (alpha === null || alpha < NEAR_OPAQUE) continue;
      if (OVERLAY_ALLOWED.has(key) || OVERLAY_PENDING.has(key)) {
        used.add(key);
        continue;
      }
      found.push(`${block.file}:${d.line}: ${block.selector} { ${d.prop}: ${d.value.replace(/\s+/g, " ")} }`);
    }
  }
  if (srcDir === SRC) {
    for (const key of [...OVERLAY_ALLOWED.keys(), ...OVERLAY_PENDING.keys()]) {
      if (!used.has(key)) found.push(`stale: ${key} is glass now (or gone); remove its entry`);
    }
  }
  return found;
}

const RULE_TEXT = [
  'The rule: "Glass, never opaque" (Leo). Popovers, cards, menus, toasts and sheets are glass:',
  "legibility comes from the blur, tint and contrast inside the glass, never an opaque or near-opaque",
  "fill. Reduce Transparency is the only opaque fallback (glass.css applies --glass-opaque under it).",
  "A surface that must stay solid is allowlisted with a written reason: /* glass-opaque-allow: <reason> */",
  "before its fill, or an OVERLAY_ALLOWED entry (design/overlay-surfaces.md in leo-workspace).",
].join("\n  ");

if (import.meta.main) {
  let failed = false;
  for (const line of findSolidTooltipMarkup()) {
    console.error(`a tooltip is never solid (add ui-glass): ${line}`);
    failed = true;
  }
  for (const line of findMissingGlassMarkup()) {
    console.error(`a floating surface is glass (add ui-glass): ${line}`);
    failed = true;
  }
  for (const line of findOpaqueGlass()) {
    console.error(`glass is never opaque: ${line}`);
    failed = true;
  }
  for (const line of findOpaqueOverlays()) {
    console.error(`an overlay surface is glass, never opaque: ${line}`);
    failed = true;
  }
  if (failed) {
    console.error(`  ${RULE_TEXT}`);
    process.exitCode = 1;
  } else console.log("Glass fills checked: none opaque.");
}
