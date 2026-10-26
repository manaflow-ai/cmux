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
const REQUIRED_GLASS_CLASSES = new Set(["acpmux-omni"]);
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

if (import.meta.main) {
  for (const line of findSolidTooltipMarkup()) {
    console.error(`a tooltip is never solid (add ui-glass): ${line}`);
    process.exitCode = 1;
  }
  for (const line of findMissingGlassMarkup()) {
    console.error(`a floating surface is glass (add ui-glass): ${line}`);
    process.exitCode = 1;
  }
  const found = findOpaqueGlass();
  for (const line of found) console.error(`glass is never opaque: ${line}`);
  if (found.length) process.exitCode = 1;
  else console.log("Glass fills checked: none opaque.");
}
