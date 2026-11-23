// Horizontal padding across every webviews stylesheet: a static bench, no browser. Leo, 2026-10-21:
// "AND I SAID STOP WITH TEH FUCKING INCESSEANT LEFT RIGHT FUCKING PADDING". It reads every CSS rule
// under src/ (galleries and generated sheets left out), resolves each left and right padding to px
// (var() through the custom properties the sheets define, with their fallbacks; calc() with plain
// arithmetic; em/rem at 13 px), and prints:
//   rules      rules that set a horizontal padding at all;
//   sum        left + right px over those rules (the headline: lower is less width spent on nothing);
//   wide       sides of 16 px or more; widest: the largest side;
//   top        the widest rules, with file:line, so an audit starts from the worst.
// A rule whose value it cannot resolve (%, vw, an unknown var) is counted in `unresolved`, not guessed.
// It reports and never fails: a measurement, not a check.
//   bun bench/horizontal-padding.bench.ts [top=25] [--json]
/// <reference types="bun" />
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "..", "src");
const TOP = Number(process.argv.find((arg) => /^\d+$/.test(arg)) ?? 25);
const JSON_OUT = process.argv.includes("--json");
const EM = 13;
const WIDE = 16;

export function cssFiles(dir: string = SRC): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (["node_modules", "generated", "gallery"].includes(entry.name)) return [];
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return cssFiles(full);
    return entry.name.endsWith(".css") && !entry.name.includes(".gallery.") ? [full] : [];
  });
}

const stripComments = (text: string) => text.replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, " "));

/** Innermost rule blocks: `selector { decls }` with no nested braces in decls. */
function* rules(text: string): Generator<{ selector: string; body: string; index: number }> {
  const plain = stripComments(text);
  const rule = /([^{}]+)\{([^{}]*)\}/g;
  for (let m = rule.exec(plain); m; m = rule.exec(plain)) {
    const selector = m[1]!.trim().split(/[;}]/).pop()!.trim();
    yield { selector, body: m[2]!, index: m.index + m[0].indexOf("{") + 1 };
  }
}

function* decls(body: string): Generator<{ prop: string; value: string; index: number }> {
  const decl = /([\w-]+)\s*:\s*([^;]+)/g;
  for (let d = decl.exec(body); d; d = decl.exec(body))
    yield { prop: d[1]!.toLowerCase(), value: d[2]!.trim(), index: d.index };
}

/** Every custom property's raw definitions, from every rule in every sheet (first plain px wins). */
export function customProperties(files: string[]): Map<string, string> {
  const all = new Map<string, string[]>();
  for (const file of files)
    for (const r of rules(readFileSync(file, "utf8")))
      for (const d of decls(r.body))
        if (d.prop.startsWith("--")) all.set(d.prop, [...(all.get(d.prop) ?? []), d.value]);
  const out = new Map<string, string>();
  for (const [name, values] of all) out.set(name, values.find((v) => /^-?[\d.]+px$/.test(v)) ?? values[0]!);
  return out;
}

/** One length to px, or null. */
export function toPx(value: string, vars: Map<string, string>, depth = 0): number | null {
  if (depth > 12) return null;
  let text = value.replace(/!important/g, "").trim();
  // var(--x, fallback) innermost first.
  for (let guard = 0; guard < 50 && text.includes("var("); guard++) {
    const m = /var\(\s*(--[\w-]+)\s*(?:,\s*([^()]*(?:\([^()]*\)[^()]*)*))?\)/.exec(text);
    if (!m) return null;
    const def = vars.get(m[1]!);
    const px = def !== undefined ? toPx(def, vars, depth + 1) : m[2] !== undefined ? toPx(m[2], vars, depth + 1) : null;
    if (px === null) return null;
    text = text.slice(0, m.index) + `${px}px` + text.slice(m.index + m[0].length);
  }
  text = text.replace(/(-?[\d.]+)r?em\b/g, (_, n) => `${Number(n) * EM}px`);
  if (/%|vw|vh|cqi|ch\b|ex\b|env\(/.test(text)) return null;
  text = text.replace(/\b(calc|max|min|clamp)\(/g, (_, f) =>
    f === "calc" ? "(" : `Math.${f === "clamp" ? "clampf" : f}(`,
  );
  const expr = text.replace(/(-?[\d.]+)px/g, "$1");
  if (!/^[\d.\s+\-*/(),Mathaxinclmpf]*$/.test(expr)) return null;
  try {
    const clampf = (lo: number, v: number, hi: number) => Math.min(Math.max(lo, v), hi);
    const result = Function(
      "clampf",
      `"use strict"; const M = Math; return (${expr.replace(/Math\.clampf/g, "clampf")});`,
    )(clampf);
    return typeof result === "number" && Number.isFinite(result) ? result : null;
  } catch {
    return null;
  }
}

/** Split a shorthand on top-level spaces. */
function parts(value: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let cur = "";
  for (const ch of value.replace(/!important/g, "").trim()) {
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (/\s/.test(ch) && depth === 0) {
      if (cur) out.push(cur);
      cur = "";
    } else cur += ch;
  }
  if (cur) out.push(cur);
  return out;
}

/** [left, right] raw values a declaration sets, or null when it sets no horizontal padding. */
export function horizontal(prop: string, value: string): [string | undefined, string | undefined] | null {
  const p = parts(value);
  switch (prop) {
    case "padding":
      return p.length === 1 ? [p[0], p[0]] : p.length <= 3 ? [p[1], p[1]] : [p[3], p[1]];
    case "padding-inline":
      return [p[0], p[1] ?? p[0]];
    case "padding-left":
    case "padding-inline-start":
      return [value, undefined];
    case "padding-right":
    case "padding-inline-end":
      return [undefined, value];
    default:
      return null;
  }
}

export interface PaddingRow {
  file: string;
  line: number;
  selector: string;
  left: number;
  right: number;
}

export function measure(files: string[] = cssFiles()) {
  const vars = customProperties(files);
  const rows: PaddingRow[] = [];
  let unresolved = 0;
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    for (const r of rules(text)) {
      if (r.selector.startsWith("@") || /^(from|to|\d+%)/.test(r.selector)) continue;
      let left = 0;
      let right = 0;
      let any = false;
      for (const d of decls(r.body)) {
        const side = horizontal(d.prop, d.value);
        if (!side) continue;
        const l = side[0] === undefined ? undefined : toPx(side[0], vars);
        const rr = side[1] === undefined ? undefined : toPx(side[1], vars);
        if (l === null || rr === null) {
          unresolved++;
          continue;
        }
        any = true;
        if (l !== undefined) left = l;
        if (rr !== undefined) right = rr;
      }
      if (!any || (left <= 0 && right <= 0)) continue;
      rows.push({
        file: path.relative(SRC, file),
        line: text.slice(0, r.index).split("\n").length,
        selector: r.selector.replace(/\s+/g, " ").slice(0, 90),
        left: Math.max(0, left),
        right: Math.max(0, right),
      });
    }
  }
  const sides = rows.flatMap((row) => [row.left, row.right]);
  return {
    rules: rows.length,
    sum: Math.round(sides.reduce((a, b) => a + b, 0)),
    wide: sides.filter((px) => px >= WIDE).length,
    widest: Math.max(0, ...sides),
    unresolved,
    rows: rows.sort((a, b) => Math.max(b.left, b.right) - Math.max(a.left, a.right)),
  };
}

if (import.meta.main) {
  const result = measure();
  if (JSON_OUT) {
    console.log(JSON.stringify({ ...result, rows: result.rows.slice(0, TOP) }, null, 2));
  } else {
    console.log(
      `horizontal padding: rules=${result.rules} sum=${result.sum}px wide(>=${WIDE}px sides)=${result.wide} ` +
        `widest=${result.widest}px unresolved=${result.unresolved} (static, webviews/src CSS)`,
    );
    for (const row of result.rows.slice(0, TOP))
      console.log(`  ${row.left}/${row.right}px  ${row.file}:${row.line}  ${row.selector}`);
  }
}
