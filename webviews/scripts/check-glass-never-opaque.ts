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
const NAMED_TRANSLUCENT = new Set(["transparent"]);
const NAMED_UNKNOWN = new Set(["currentcolor", "inherit", "initial", "unset", "revert", "none"]);

type Kind = "opaque" | "translucent" | "unknown";
interface Block {
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

/** Every glass fill under src/ that is opaque, as `file:line: selector { prop: value }`. */
export function findOpaqueGlass(srcDir: string = SRC): string[] {
  const parsed = cssFiles(srcDir).flatMap((file) => parse(relative(srcDir, file), readFileSync(file, "utf8")));
  tokens = new Map();
  for (const block of parsed) {
    if (inReduce(block)) continue;
    for (const d of block.decls) {
      if (!d.prop.startsWith("--")) continue;
      tokens.set(d.prop, [...(tokens.get(d.prop) ?? []), d.value]);
    }
  }
  const found: string[] = [];
  for (const block of parsed) {
    if (inReduce(block)) continue;
    // Glass: a blur, or a class named glass (`.sa-glass`).
    const glass = blurs(block) || /\.[\w-]*glass[\w-]*/i.test(block.selector);
    for (const d of block.decls) {
      if (d.allowed) continue;
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

if (import.meta.main) {
  const found = findOpaqueGlass();
  for (const line of found) console.error(`glass is never opaque: ${line}`);
  if (found.length) process.exitCode = 1;
  else console.log("Glass fills checked: none opaque.");
}
