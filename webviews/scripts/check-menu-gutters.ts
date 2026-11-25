// Menus spend no width on nothing (leo-workspace design/menus.md). Leo, 2026-10-28: "there's so much
// unnecessary padding that you just duplicate"; 2026-10-29: "misaligned checkmark :( can we all audit
// the checkmarks and whatnot". A menu's checkmark sits on the AppKit state column (10, design/grid.md
// 5.3) in a box no wider than its glyph, and a row's columns are 6 apart (schemas/menu-metrics
// iconGap). This fails a CSS rule for a menu check (`.ui-menu-check`, `*-menu-check`) or a menu row
// (`*-menu-item`) that sets a fixed width over 12px, or a gap over 6px, unless the line before the
// declaration (or the declaration's own line) says `menu-gutter-allow: <reason>`.
// test/check-menu-gutters.test.ts runs it; `bun scripts/check-menu-gutters.ts` runs it alone.
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../src");
const ALLOW = /menu-gutter-allow:\s*\S/;
const CHECK = /\.(?:ui-menu-check|[\w-]*-menu-check)(?![\w-])/;
const ROW = /\.[\w-]*-menu-item(?![\w-])/;
const WIDTH = /^(?:width|min-width|flex-basis|inline-size|min-inline-size)$/;
const GAP = /^(?:gap|column-gap)$/;

export type GutterFinding = { file: string; line: number; selector: string; prop: string; value: string };

function cssFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name === "node_modules" || entry.name === "generated") return [];
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return cssFiles(path);
    return entry.name.endsWith(".css") ? [path] : [];
  });
}

/** The largest px length in a value (`16px`, `calc(8px * 2)` reads 8); null without one. */
function pixels(value: string): number | null {
  const all = [...value.matchAll(/(-?[\d.]+)px/g)].map((match) => Number(match[1]));
  if (all.length === 0) return /^0$/.test(value.trim()) ? 0 : null;
  return Math.max(...all);
}

/** Menu-gutter findings in one stylesheet's text. */
export function findMenuGutters(file: string, text: string): GutterFinding[] {
  const findings: GutterFinding[] = [];
  const lines = text.split("\n");
  const lineOf = (index: number) => text.slice(0, index).split("\n").length;
  // Comments go to spaces so offsets (and lines) stay; the allow comment is read from the raw lines.
  const plain = text.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
  const rule = /([^{}]+)\{([^{}]*)\}/g;
  for (let match = rule.exec(plain); match; match = rule.exec(plain)) {
    const selector = match[1]!.trim();
    if (selector.startsWith("@")) continue;
    const isCheck = CHECK.test(selector);
    const isRow = ROW.test(selector);
    if (!isCheck && !isRow) continue;
    const bodyStart = match.index + match[0].indexOf("{") + 1;
    const decl = /([\w-]+)\s*:\s*([^;]+)/g;
    for (let d = decl.exec(match[2]!); d; d = decl.exec(match[2]!)) {
      const prop = d[1]!.toLowerCase();
      const value = d[2]!.trim();
      const px = pixels(value);
      if (px === null) continue;
      const tooWide = isCheck && WIDTH.test(prop) && px > 12;
      const tooFar = GAP.test(prop) && px > 6;
      if (!tooWide && !tooFar) continue;
      const line = lineOf(bodyStart + d.index);
      if (ALLOW.test(lines[line - 1] ?? "") || ALLOW.test(lines[line - 2] ?? "")) continue;
      findings.push({ file, line, selector: selector.replace(/\s+/g, " ").slice(0, 120), prop, value });
    }
  }
  return findings;
}

/** Every finding under src/. */
export function findAllMenuGutters(srcDir: string = SRC): GutterFinding[] {
  return cssFiles(srcDir).flatMap((path) => findMenuGutters(relative(srcDir, path), readFileSync(path, "utf8")));
}

if (import.meta.main) {
  const found = findAllMenuGutters();
  for (const f of found)
    console.error(
      `menu gutter: ${f.file}:${f.line}: ${f.selector} { ${f.prop}: ${f.value} } ` +
        "(a menu check is no wider than 12 and a row's gap no more than 6; say menu-gutter-allow: <reason> to keep it)",
    );
  if (found.length) process.exitCode = 1;
  else console.log("Menu gutters checked: none wider than the glyph.");
}
