// No nested glass (design/glass-system.md, "One material per surface", rule R5). Leo, 2026-11-22, on the
// GitHub link hover card whose Open | chevron split drew as a capsule of glass inside the card's glass:
// "ugh there's more like doubled up glass/wack looking glass all over the place....". Nothing inside a
// floating material surface (a `.ui-glass` popup, card, tooltip, notice, dialog or composer box, or a
// `data-host-glass` surface) is itself a material: no descendant `.ui-glass`, no descendant
// backdrop-filter, no descendant host-glass mark, no translucent fill with a rim and a shadow of its
// own. A control on glass is a plain control: clear, or the theme's hover or selected fill, and one
// hairline at most (menu rows, ui/Button's ghost variant).
//
// The static half, as pure functions; check-one-material.ts runs findNestedGlass with its own rules.
//
//  css  a rule whose selector reaches its subject through a descendant or child combinator from a
//       floating surface (FLOATING_CSS) and declares a backdrop-filter other than none, or a
//       translucent fill with both a rim (an inset shadow or a border) and an outer shadow.
//  tsx  a JSX element carrying `ui-glass` or `data-host-glass` (or a glass-rendering component,
//       GLASS_COMPONENTS) whose JSX ancestor in the same tree is a floating surface (a floating class,
//       a host-glass mark, or a component whose root is one, FLOATING_COMPONENTS). A portal or a
//       positioner (a new layer, drawn outside its parent's box) starts a new tree.
//
// A case that is no material says why: `one-material-allow: <reason>`, in the rule or on the line before
// its selector (CSS), inside the opening tag or on the line before it (TSX). The allowed count is pinned
// (NESTED_ALLOWED_MAX): it can only shrink.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { parseCss, translucent } from "./check-one-material";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, "../src");

/** How many nested cases may carry `one-material-allow`. Lower it when one goes; never raise it. */
export const NESTED_ALLOWED_MAX = 2;

const ALLOW = /one-material-allow:\s*\S/;
const SKIP_FILE = /\.(test|gallery|dom\.test|experiment)\.[cm]?[jt]sx?$|\.gallery\.css$/;
const SKIP_DIR = new Set(["node_modules", "prototypes", "prototype", "gallery", "glass-parity"]);
const NO_FILTER = /^(none|initial|inherit|unset|revert|revert-layer)$/i;

/** The classes of a floating material surface, and its host-glass mark. */
export const FLOATING_CSS = [
  "ui-popup",
  "ui-card",
  "ui-tooltip",
  "ui-notice",
  "ui-dialog",
  "ui-glass",
  "acpmux-composer-box",
  "nt-composer-surface",
  "acpmux-minimap__card",
] as const;
const FLOATING_RE = new RegExp(
  `\\.(?:${FLOATING_CSS.map((name) => name.replace(/[-_]/g, "\\$&")).join("|")})(?![\\w-])|\\[data-host-glass(?![\\w-])`,
);

// ---------------------------------------------------------------------------------------------------
// CSS

/** `selector` split at its top-level commas. */
function splitList(selector: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < selector.length; i++) {
    const ch = selector[i];
    if (ch === "(" || ch === "[") depth++;
    else if (ch === ")" || ch === "]") depth--;
    else if (ch === "," && depth === 0) {
      parts.push(selector.slice(start, i).trim());
      start = i + 1;
    }
  }
  parts.push(selector.slice(start).trim());
  return parts.filter(Boolean);
}

/** One complex selector as its compounds and the combinator before each (" ", ">", "+", "~"). */
function compounds(selector: string): { compound: string; combinator: string }[] {
  const out: { compound: string; combinator: string }[] = [];
  let depth = 0;
  let current = "";
  let between = "";
  for (const ch of selector) {
    if (depth === 0 && (ch === ">" || ch === "+" || ch === "~" || /\s/.test(ch))) {
      if (current) {
        out.push({ compound: current, combinator: out.length === 0 ? "" : (/[>+~]/.exec(between)?.[0] ?? " ") });
        current = "";
        between = "";
      }
      between += ch;
      continue;
    }
    if (ch === "(" || ch === "[") depth++;
    else if (ch === ")" || ch === "]") depth--;
    current += ch;
  }
  if (current) out.push({ compound: current, combinator: out.length === 0 ? "" : (/[>+~]/.exec(between)?.[0] ?? " ") });
  return out;
}

/** A compound with its :not() and :has() arguments taken off: they name no ancestor. */
function ownPart(compound: string): string {
  let out = "";
  for (let i = 0; i < compound.length; i++) {
    const rest = compound.slice(i);
    const match = /^:(not|has)\(/.exec(rest);
    if (!match) {
      out += compound[i];
      continue;
    }
    let depth = 0;
    let j = i + match[0].length - 1;
    for (; j < compound.length; j++) {
      if (compound[j] === "(") depth++;
      else if (compound[j] === ")" && --depth === 0) break;
    }
    i = j;
  }
  return out;
}

/** A content-layer card (.ui-glass-content: a permission ask, a Settings card, a changelog figure)
 *  scrolls with the page and is no floating surface (design/glass-system.md rule 2). */
const CONTENT_LAYER = /\.ui-glass-content(?![\w-])/;

/** The floating compound that the selector's subject sits inside, if any. */
function floatingAncestor(selector: string): string | undefined {
  const list = compounds(selector);
  for (let i = 0; i < list.length - 1; i++) {
    const own = ownPart(list[i]!.compound);
    if (!FLOATING_RE.test(own) || CONTENT_LAYER.test(own)) continue;
    const descends = list.slice(i + 1).some((part) => part.combinator === " " || part.combinator === ">");
    if (descends) return list[i]!.compound;
  }
  return undefined;
}

/** Each selector of a rule, with its nesting parents resolved (`&`, or a parent then a space). */
function resolved(selector: string, context: string[]): string[] {
  let parents = [""];
  for (const parent of context.filter((entry) => !entry.startsWith("@"))) {
    parents = parents.flatMap((outer) =>
      splitList(parent).map((part) =>
        outer ? (part.includes("&") ? part.replace(/&/g, outer) : `${outer} ${part}`) : part,
      ),
    );
  }
  return parents.flatMap((outer) =>
    splitList(selector).map((part) =>
      outer ? (part.includes("&") ? part.replace(/&/g, outer) : `${outer} ${part}`) : part,
    ),
  );
}

/** Whether a box-shadow value has an inset part and an outer part. */
function shadowParts(value: string): { inset: boolean; outer: boolean } {
  if (NO_FILTER.test(value) || value === "") return { inset: false, outer: false };
  const parts = splitList(value);
  const inset = parts.some((part) => /\binset\b/.test(part));
  const outer = parts.some((part) => !/\binset\b/.test(part) && !/^(none|0)$/.test(part.trim()));
  return { inset, outer };
}

interface Found {
  where: string;
  message: string;
  allowed: boolean;
}

function cssCases(css: string, file: string): Found[] {
  const out: Found[] = [];
  for (const rule of parseCss(css)) {
    const filter = rule.decls.find(
      (decl) =>
        (decl.prop === "backdrop-filter" || decl.prop === "-webkit-backdrop-filter") && !NO_FILTER.test(decl.value),
    );
    const fill = rule.decls.find(
      (decl) => (decl.prop === "background" || decl.prop === "background-color") && translucent(decl.value),
    );
    const shadow = shadowParts(rule.decls.filter((decl) => decl.prop === "box-shadow").at(-1)?.value ?? "");
    const border = rule.decls.some(
      (decl) =>
        /^border(-(top|right|bottom|left))?$/.test(decl.prop) &&
        !/^(0|none)\b/.test(decl.value) &&
        !/transparent/.test(decl.value),
    );
    const material = fill && shadow.outer && (shadow.inset || border);
    if (!filter && !material) continue;
    const inside = resolved(rule.selector, rule.context)
      .map(floatingAncestor)
      .find((ancestor) => ancestor !== undefined);
    if (!inside) continue;
    const what = filter
      ? `backdrop-filter: ${filter.value}`
      : `a glass fill of its own (${fill!.prop}: ${fill!.value}) with a rim and a shadow`;
    out.push({
      where: `${file}:${rule.line}: ${rule.selector}`,
      message:
        `[nested] draws ${what} inside the floating surface ${inside}: a control on glass is a plain control ` +
        "(clear, or the hover/selected fill, one hairline at most), or say why: /* one-material-allow: <reason> */",
      allowed: rule.allowed,
    });
  }
  return out;
}

/** R5 over one stylesheet: each nested material rule that is not allowed. */
export function nestedGlassInCss(css: string, file: string): string[] {
  return cssCases(css, file)
    .filter((found) => !found.allowed)
    .map((found) => `${found.where} ${found.message}`);
}

// ---------------------------------------------------------------------------------------------------
// TSX

/** Components whose root is a floating material surface: what they wrap sits on that glass. */
export const FLOATING_COMPONENTS = ["AnchoredCard", "MenuPopup", "Popover", "Notice", "FeatureTip", "Glass"] as const;
/** Shared components that render a glass of their own: inside a floating surface, glass on glass. */
export const GLASS_COMPONENTS: Record<string, (tag: string) => boolean> = {
  // ui/glass/Glass.tsx and kit/Glass.tsx: a `.ui-glass` box.
  Glass: () => true,
  // ui/Notice.tsx: always `.ui-notice.ui-glass`.
  Notice: () => true,
  // browser-chrome/cookie-import/CookieImportCard.tsx: glass when it is told to be.
  CookieImportCard: (tag) => /\sglass(\s|=\{?true|\/?>)/.test(tag),
};
/** A new layer: drawn outside its parent's box, so its content is not inside the parent's glass. */
const LAYER = /(^|\.)(Portal|Positioner)$|Portal$/;
/** Components that draw what they wrap in a portal of their own (a new layer, on their own surface). */
export const PORTAL_COMPONENTS = ["AnchoredCard", "MenuPopup", "Popover", "FeatureTip", "Dialog", "Sheet"] as const;

const CLASS_TOKENS = /^(ui-glass|data-host-glass)$/;

interface Tag {
  name: string;
  line: number;
  floating?: string;
  glass?: string;
  layer: boolean;
}

/** The class words an opening tag names in any *className attribute (each string it could take). */
function classWords(tag: string): string[] {
  const words: string[] = [];
  const attr = /\b(\w*[cC]lass[nN]ame|class)\s*=\s*/g;
  let match: RegExpExecArray | null;
  while ((match = attr.exec(tag))) {
    let i = match.index + match[0].length;
    let value = "";
    if (tag[i] === '"' || tag[i] === "'") {
      const end = tag.indexOf(tag[i]!, i + 1);
      value = tag.slice(i + 1, end < 0 ? tag.length : end);
    } else if (tag[i] === "{") {
      let depth = 0;
      const start = i;
      for (; i < tag.length; i++) {
        if (tag[i] === "{") depth++;
        else if (tag[i] === "}" && --depth === 0) break;
      }
      const expr = tag.slice(start, i + 1);
      value = [...expr.matchAll(/"([^"]*)"|'([^']*)'|`([^`]*)`/g)].map((m) => m[1] ?? m[2] ?? m[3] ?? "").join(" ");
    }
    words.push(...value.split(/[\s${}]+/).filter(Boolean));
  }
  return words;
}

/** What makes an opening tag a material: its glass class, its host-glass mark, or a glass component. */
function materialOf(name: string, tag: string, local: ReadonlySet<string>): { floating?: string; glass?: string } {
  const words = classWords(tag);
  const hostMark = /(^|[\s{,])["']?data-host-glass["']?\s*[=:]\s*(?!\{?\s*undefined\b)/.test(tag);
  const floatingClass = words.find((word) => FLOATING_CSS.includes(word as (typeof FLOATING_CSS)[number]));
  const glassClass = words.find((word) => CLASS_TOKENS.test(word));
  const base = name.split(".").at(-1)!;
  const glassComponent = GLASS_COMPONENTS[base]?.(tag) || local.has(base) ? `<${name}>` : undefined;
  const glass = glassClass ? `.${glassClass}` : hostMark ? "data-host-glass" : glassComponent;
  const content = words.includes("ui-glass-content");
  const floating =
    (floatingClass && !content ? `.${floatingClass}` : undefined) ??
    (hostMark ? "data-host-glass" : undefined) ??
    ((FLOATING_COMPONENTS as readonly string[]).includes(base) ? `<${name}>` : undefined);
  return { floating, glass };
}

/** Each JSX opening tag in a TSX source, with the JSX ancestors it sits in. */
function* jsxTags(
  source: string,
  local: ReadonlySet<string> = new Set(),
): Generator<{ tag: Tag; text: string; ancestors: Tag[]; index: number }> {
  // An element is first its opening tag (`closeAt`: the index after its `>`), whose attribute
  // expressions may hold JSX (a render prop) drawn inside it, then its children.
  type Frame =
    | { kind: "el"; tag: Tag; opening: boolean; closeAt: number; selfClosing: boolean }
    | { kind: "js"; depth: number; layer: boolean };
  const stack: Frame[] = [];
  const lineAt = (() => {
    const starts = [0];
    for (let i = 0; i < source.length; i++) if (source[i] === "\n") starts.push(i + 1);
    return (index: number) => {
      let lo = 0;
      let hi = starts.length - 1;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (starts[mid]! <= index) lo = mid;
        else hi = mid - 1;
      }
      return lo + 1;
    };
  })();
  /** Whether a `/` at `i` opens a regular expression literal (after an operator, not a value). */
  const regexStarts = (i: number): boolean => {
    let j = i - 1;
    while (j >= 0 && /[ \t]/.test(source[j]!)) j--;
    if (j < 0) return true;
    const prev = source[j]!;
    if (/[(,=:[!&|?{;+\-*%~^\n]/.test(prev)) return true;
    const word = /(\w+)$/.exec(source.slice(Math.max(0, j - 10), j + 1))?.[1];
    return word === "return" || word === "typeof" || word === "case";
  };
  /** Skips a string, template or comment at `i`; returns the index after it, or -1 if none starts there. */
  const skipLiteral = (i: number): number => {
    const ch = source[i];
    if (ch === "/" && source[i + 1] === "/") {
      const end = source.indexOf("\n", i);
      return end < 0 ? source.length : end;
    }
    if (ch === "/" && source[i + 1] === "*") {
      const end = source.indexOf("*/", i + 2);
      return end < 0 ? source.length : end + 2;
    }
    if (ch === "/" && regexStarts(i)) {
      let inClass = false;
      for (let j = i + 1; j < source.length; j++) {
        const c = source[j];
        if (c === "\\") j++;
        else if (c === "[") inClass = true;
        else if (c === "]") inClass = false;
        else if (c === "\n") return j;
        else if (c === "/" && !inClass) return j + 1;
      }
      return source.length;
    }
    if (ch === '"' || ch === "'") {
      for (let j = i + 1; j < source.length; j++) {
        if (source[j] === "\\") j++;
        else if (source[j] === ch || source[j] === "\n") return j + 1;
      }
      return source.length;
    }
    if (ch === "`") {
      let depth = 0;
      for (let j = i + 1; j < source.length; j++) {
        if (source[j] === "\\") j++;
        else if (source[j] === "$" && source[j + 1] === "{") {
          depth++;
          j++;
        } else if (source[j] === "}" && depth > 0) depth--;
        else if (source[j] === "`" && depth === 0) return j + 1;
      }
      return source.length;
    }
    return -1;
  };
  /** Whether a `<` at `i` in code opens JSX (not a comparison or a type argument). */
  const opensJsx = (i: number): boolean => {
    if (!/[A-Za-z>]/.test(source[i + 1] ?? "")) return false;
    let j = i - 1;
    while (j >= 0 && /\s/.test(source[j]!)) j--;
    if (j < 0) return true;
    const prev = source[j]!;
    if (/[\w$)\]]/.test(prev)) {
      const word = /(\w+)$/.exec(source.slice(Math.max(0, j - 10), j + 1))?.[1];
      return word === "return" || word === "yield" || word === "default" || word === "in" || word === "of";
    }
    if (prev === ">" && source[j - 1] !== "=") return false;
    const after = /^<([A-Za-z_$][\w.$:-]*)\s*(,|extends\b)/.exec(source.slice(i, i + 80));
    return !after;
  };
  /** Reads an opening tag at `i`: its name, its text and where it ends. */
  const readTag = (i: number) => {
    const name = /^<([A-Za-z_$][\w.$:-]*)?/.exec(source.slice(i))?.[1] ?? "";
    let j = i + 1 + name.length;
    let depth = 0;
    for (; j < source.length; j++) {
      const ch = source[j]!;
      if (depth === 0 && ch === "/" && (source[j + 1] === "/" || source[j + 1] === "*")) {
        j = skipLiteral(j) - 1;
        continue;
      }
      if (depth === 0 && (ch === '"' || ch === "'")) {
        const end = source.indexOf(ch, j + 1);
        j = end < 0 ? source.length : end;
        continue;
      }
      if (depth > 0) {
        const skipped = skipLiteral(j);
        if (skipped >= 0) {
          j = skipped - 1;
          continue;
        }
      }
      if (ch === "{") depth++;
      else if (ch === "}") depth--;
      else if (ch === ">" && depth === 0) break;
    }
    const text = source.slice(i, j + 1);
    return { name, text, end: j + 1, selfClosing: source[j - 1] === "/" };
  };

  let i = 0;
  while (i < source.length) {
    const top = stack.at(-1);
    const ch = source[i]!;
    if (top?.kind === "el" && top.opening) {
      if (i >= top.closeAt - 1) {
        i = top.closeAt;
        if (top.selfClosing) stack.pop();
        else top.opening = false;
        continue;
      }
      if (ch === "{") {
        stack.push({ kind: "js", depth: 1, layer: false });
        i++;
        continue;
      }
      if (ch === '"' || ch === "'") {
        const end = source.indexOf(ch, i + 1);
        i = end < 0 ? source.length : end + 1;
        continue;
      }
      const skipped = ch === "/" && (source[i + 1] === "/" || source[i + 1] === "*") ? skipLiteral(i) : -1;
      i = skipped >= 0 ? skipped : i + 1;
      continue;
    }
    if (top?.kind === "el") {
      // JSX children: text, child tags, a closing tag, or an expression.
      if (ch === "{") {
        stack.push({ kind: "js", depth: 1, layer: false });
        i++;
        continue;
      }
      if (ch === "<" && source[i + 1] === "/") {
        const end = source.indexOf(">", i);
        const name = source.slice(i + 2, end).trim();
        let at = stack.length - 1;
        while (at >= 0) {
          const frame = stack[at]!;
          if (frame.kind === "el" && !frame.opening && frame.tag.name === name) break;
          at--;
        }
        if (at >= 0) stack.length = at;
        else stack.pop();
        i = end < 0 ? source.length : end + 1;
        continue;
      }
      if (ch === "<" && /[A-Za-z>]/.test(source[i + 1] ?? "")) {
        // falls through to the tag reader below
      } else {
        i++;
        continue;
      }
    } else {
      const skipped = skipLiteral(i);
      if (skipped >= 0) {
        i = skipped;
        continue;
      }
      if (top?.kind === "js") {
        if (ch === "{") top.depth++;
        else if (ch === "}" && --top.depth === 0) {
          stack.pop();
          i++;
          continue;
        }
        if (source.startsWith("createPortal(", i)) top.layer = true;
      }
      if (ch !== "<" || !opensJsx(i)) {
        i++;
        continue;
      }
    }
    const read = readTag(i);
    const line = lineAt(i);
    const material = materialOf(read.name, read.text, local);
    const base = read.name.split(".").at(-1)!;
    const portal = (PORTAL_COMPONENTS as readonly string[]).includes(base);
    const tag: Tag = { name: read.name, line, ...material, layer: LAYER.test(read.name) || portal };
    const ancestors: Tag[] = [];
    for (let k = stack.length - 1; k >= 0; k--) {
      const frame = stack[k]!;
      if (frame.kind === "js") {
        if (frame.layer) break;
        continue;
      }
      // A portal's own surface holds what it wraps; past it, nothing is the content's box.
      ancestors.push(frame.tag);
      if (frame.tag.layer) break;
    }
    if (read.name) yield { tag, text: read.text, ancestors, index: i };
    stack.push({ kind: "el", tag, opening: true, closeAt: read.end, selfClosing: read.selfClosing });
    i += 1 + read.name.length;
  }
}

/** The file's own components that draw a glass in their own box (not in a portal): drawn inside a
 *  floating surface, each is glass on glass. Read to a fixed point, as one may draw another. */
function localGlassComponents(source: string): Set<string> {
  const starts = [
    ...source.matchAll(/^(?:export\s+)?(?:default\s+)?(?:function\s+([A-Z]\w*)|const\s+([A-Z]\w*)\s*[:=])/gm),
  ].map((match) => ({ index: match.index, name: (match[1] ?? match[2])! }));
  const owner = (index: number) => [...starts].reverse().find((start) => start.index <= index)?.name;
  const local = new Set<string>();
  for (let round = 0; round < 4; round++) {
    const size = local.size;
    for (const { tag, ancestors, index } of jsxTags(source, local)) {
      if (!tag.glass || tag.layer || ancestors.some((ancestor) => ancestor.layer)) continue;
      const name = owner(index);
      if (name) local.add(name);
    }
    if (local.size === size) break;
  }
  return local;
}

function tsxCases(source: string, file: string): Found[] {
  const lines = source.split("\n");
  const out: Found[] = [];
  for (const { tag, text, ancestors } of jsxTags(source, localGlassComponents(source))) {
    // A portal's own surface is a new layer, not inside its parent's glass.
    if (!tag.glass || tag.layer) continue;
    const surface = ancestors.find((ancestor) => ancestor.floating);
    if (!surface) continue;
    out.push({
      where: `${file}:${tag.line}: <${tag.name}>`,
      message:
        `[nested] carries ${tag.glass} inside the floating surface <${surface.name}> (${surface.floating}, line ${surface.line}): ` +
        "a control on glass is a plain control (clear, or the hover/selected fill, one hairline at most), " +
        "or say why: {/* one-material-allow: <reason> */} in the tag or on the line before it",
      allowed: ALLOW.test(text) || ALLOW.test(lines[tag.line - 2] ?? ""),
    });
  }
  return out;
}

/** R5 over one component file: each nested glass element that is not allowed. */
export function nestedGlassInTsx(source: string, file: string): string[] {
  return tsxCases(source, file)
    .filter((found) => !found.allowed)
    .map((found) => `${found.where} ${found.message}`);
}

// ---------------------------------------------------------------------------------------------------
// The tree

function* walk(dir: string): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIR.has(entry.name)) yield* walk(full);
    } else if (/\.(css|tsx)$/.test(entry.name) && !SKIP_FILE.test(entry.name)) yield full;
  }
}

/** R5 over every stylesheet and component under `root` (webviews/src); `allowed` lists each allowed case. */
export function findNestedGlass(root: string = SRC): { errors: string[]; allowed: string[] } {
  const errors: string[] = [];
  const allowed: string[] = [];
  for (const path of walk(root)) {
    const file = relative(root, path);
    const text = readFileSync(path, "utf8");
    for (const found of path.endsWith(".css") ? cssCases(text, file) : tsxCases(text, file)) {
      if (found.allowed) allowed.push(found.where);
      else errors.push(`${found.where} ${found.message}`);
    }
  }
  if (allowed.length > NESTED_ALLOWED_MAX)
    errors.push(
      `${allowed.length} nested cases carry one-material-allow, past NESTED_ALLOWED_MAX (${NESTED_ALLOWED_MAX}): ` +
        "make one a plain control instead of allowing it",
    );
  return { errors, allowed };
}

if (import.meta.main) {
  const { errors, allowed } = findNestedGlass();
  for (const line of allowed) console.log(`allowed ${line}`);
  for (const line of errors) console.error(line);
  console.log(`${errors.length} nested glass case(s), ${allowed.length} allowed`);
  process.exit(errors.length > 0 ? 1 : 0);
}
