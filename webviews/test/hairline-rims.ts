// The scanner behind test/hairline-rims.test.ts (cx-o9yox, follow-up to #20481). macOS WebKit
// paints a rim thinner than one device pixel (an inset or spread box-shadow ring, or a border) on a
// rounded box as the rounded outer clip minus a hole snapped to device pixels, so on a 1x display
// or at a fractional page zoom the rim loses whole edges and the corner arcs beside them. A rim on a
// rounded element names its width with `var(--cmux-hairline)` (one device pixel) or
// `var(--cmux-hairline-ring)` (pages/shared/desktop.css), never a raw sub-pixel length such as
// `0.5px`.
//
// A rim counts as rounded when its rule, or another rule in the same file whose selector ends in
// the same class, sets a non-zero border-radius; in TSX, a class list with a sub-pixel Tailwind
// border width and a `rounded` utility. A custom property holding a sub-pixel ring shadow layer (an
// elevation token) always counts. Straight one-side separators (`border-top: .5px`) are left alone:
// WebKit draws a straight sub-pixel border as one device pixel. So are offset insets
// (`inset 0 .5px 0`), which draw one side. Known limits: a radius set in another file, or on a
// selector without a class, is not seen, and a width kept in its own custom property is not traced. A rule (or the comment line above a TSX line) marked
// `hairline-allow: <reason>` is exempt.
import fs from "node:fs";
import path from "node:path";

export const SRC = path.resolve(import.meta.dir, "../src");

export interface Rim {
  /** Relative to src/. */
  file: string;
  line: number;
  selector: string;
  text: string;
}

const ALLOW = /hairline-allow:\s*\S/;
/** A positive length under one CSS pixel: `.5px`, `0.5px`, `0.33px`. */
const SUB_PIXEL = /(?<![\w.-])0?\.\d+px\b/;
const RIM_PROPERTY =
  /^(?:border(?:-(?:top|right|bottom|left|block|inline)(?:-(?:start|end))?)?(?:-width)?|outline(?:-width)?|box-shadow)$/i;
/** A non-zero border-radius (any corner). */
const RADIUS = /^border(?:-[a-z]+)*-radius$/i;
const ZERO_RADIUS = /^\s*(?:0(?:px)?\s*)+(?:!important)?\s*$/;
/** Tailwind: `border-[0.5px]`, `border-t-[.5px]`, `outline-[0.5px]`, `ring-[0.5px]`. */
const TW_RIM = /(?<![-\w])(?:[\w-]+:)*(?:border(?:-[trblxy]|-[se])?|outline|ring)-\[0?\.\d+px\]/;
const TW_ROUNDED = /(?<![-\w])(?:[\w-]+:)*rounded(?!-none\b)(?:-[\w[\].]+)?(?![-\w])/;

function files(dir: string): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "generated") continue;
      out.push(...files(full));
    } else if (/\.(css|tsx?)$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name) && !entry.name.endsWith(".d.ts")) {
      out.push(full);
    }
  }
  return out;
}

/** Top-level comma split of a selector list. */
function selectorParts(selector: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < selector.length; index++) {
    const char = selector[index];
    if (char === "(" || char === "[") depth++;
    else if (char === ")" || char === "]") depth--;
    else if (char === "," && depth === 0) {
      parts.push(selector.slice(start, index));
      start = index + 1;
    }
  }
  parts.push(selector.slice(start));
  return parts.map((part) => part.trim()).filter(Boolean);
}

/** The classes of a selector part's subject (its last compound), pseudo-classes dropped. */
function subjectClasses(part: string): string[] {
  const stripped = part.replace(/\((?:[^()]|\([^()]*\))*\)/g, "").replace(/\[[^\]]*\]/g, "");
  const compounds = stripped.split(/\s*[\s>+~]\s*/).filter(Boolean);
  const last = (compounds.at(-1) ?? "").replace(/::?[\w-]+/g, "");
  return [...last.matchAll(/\.([\w-]+)/g)].map((match) => match[1]!);
}

/** A rim declaration's width is sub-pixel (box-shadow: a layer whose blur is 0 and spread is sub-pixel;
 * a layer that names the hairline token is fine, the others are still checked). */
function subPixelRim(property: string, value: string): boolean {
  if (!RIM_PROPERTY.test(property) || !SUB_PIXEL.test(value)) return false;
  if (!/^box-shadow$/i.test(property)) return !/var\(--cmux-hairline(?![\w-])/.test(value);
  return splitTop(value).some((entry) => {
    if (/var\(--cmux-hairline/.test(entry)) return false;
    const lengths = entry
      .replace(/\b(?:rgba?|hsla?|color-mix|color|oklch|oklab|lab|lch|var)\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)/g, "")
      .match(/-?(?:\d*\.)?\d+(?:px)?\b/g);
    if (!lengths || lengths.length < 4) return false;
    const spread = Number.parseFloat(lengths[3]!);
    const blur = Number.parseFloat(lengths[2]!);
    return blur === 0 && spread > 0 && spread < 1;
  });
}

function splitTop(value: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < value.length; index++) {
    const char = value[index];
    if (char === "(") depth++;
    else if (char === ")") depth--;
    else if (char === "," && depth === 0) {
      out.push(value.slice(start, index));
      start = index + 1;
    }
  }
  out.push(value.slice(start));
  return out;
}

interface Rule {
  selector: string;
  body: string;
  /** Offset of the body in the file. */
  at: number;
  allowed: boolean;
}

function cssRules(text: string): Rule[] {
  const rules: Rule[] = [];
  for (const match of text.matchAll(/([^{}]*)\{([^{}]*)\}/g)) {
    const raw = match[1]!;
    const body = match[2]!;
    const selector = raw.replace(/\/\*[\s\S]*?\*\//g, "").trim();
    if (!selector || selector.startsWith("@")) continue;
    rules.push({
      selector,
      body,
      at: match.index! + raw.length + 1,
      allowed: ALLOW.test(raw) || ALLOW.test(body),
    });
  }
  return rules;
}

function declarations(body: string): { property: string; value: string; offset: number }[] {
  const out: { property: string; value: string; offset: number }[] = [];
  const clean = body.replace(/\/\*[\s\S]*?\*\//g, (comment) => " ".repeat(comment.length));
  let offset = 0;
  for (const piece of clean.split(";")) {
    const colon = piece.indexOf(":");
    if (colon > 0) {
      const property = piece.slice(0, colon).trim();
      out.push({ property, value: piece.slice(colon + 1).trim(), offset: offset + piece.search(/\S/) });
    }
    offset += piece.length + 1;
  }
  return out;
}

function scanCss(file: string, text: string): Rim[] {
  const rules = cssRules(text);
  const rounded = new Set<string>();
  for (const rule of rules) {
    if (!declarations(rule.body).some((d) => RADIUS.test(d.property) && !ZERO_RADIUS.test(d.value))) continue;
    for (const part of selectorParts(rule.selector)) for (const name of subjectClasses(part)) rounded.add(name);
  }
  const rims: Rim[] = [];
  for (const rule of rules) {
    if (rule.allowed) continue;
    const decls = declarations(rule.body);
    const ownRadius = decls.some((d) => RADIUS.test(d.property) && !ZERO_RADIUS.test(d.value));
    const isRounded =
      ownRadius || selectorParts(rule.selector).some((part) => subjectClasses(part).some((name) => rounded.has(name)));
    for (const decl of decls) {
      // A shadow token (`--ui-popup-shadow: ..., inset 0 0 0 0.5px ...`) is a rim wherever it is
      // used, and the surfaces that use one (menus, popovers, cards) are rounded.
      const token = decl.property.startsWith("--") && subPixelRim("box-shadow", decl.value);
      if (!token && !(isRounded && subPixelRim(decl.property, decl.value))) continue;
      const at = rule.at + decl.offset;
      rims.push({
        file,
        line: text.slice(0, at).split("\n").length,
        selector: rule.selector.replace(/\s+/g, " "),
        text: `${decl.property}: ${decl.value.replace(/\s+/g, " ")}`,
      });
    }
  }
  return rims;
}

function scanTsx(file: string, text: string): Rim[] {
  const rims: Rim[] = [];
  const lines = text.split("\n");
  lines.forEach((line, index) => {
    if (ALLOW.test(line) || (index > 0 && ALLOW.test(lines[index - 1]!))) return;
    for (const literal of line.matchAll(/"([^"]*)"|`([^`]*)`|'([^']*)'/g)) {
      const classes = literal[1] ?? literal[2] ?? literal[3] ?? "";
      const rim = classes.match(TW_RIM);
      if (rim && TW_ROUNDED.test(classes)) rims.push({ file, line: index + 1, selector: "className", text: rim[0] });
    }
  });
  return rims;
}

/** Every raw sub-pixel rim on a rounded element under `root` (default: webviews/src). */
export function scan(root: string = SRC): Rim[] {
  const rims: Rim[] = [];
  for (const full of files(root).sort()) {
    const file = path.relative(root, full);
    const text = fs.readFileSync(full, "utf8");
    rims.push(...(full.endsWith(".css") ? scanCss(file, text) : scanTsx(file, text)));
  }
  return rims;
}

/** Findings per file. */
export function counts(rims: readonly Rim[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const rim of rims) out[rim.file] = (out[rim.file] ?? 0) + 1;
  return out;
}
