// Icons draw on one scale (leo-workspace design/grid.md, "Icon sizes"): 12 for status marks, chevrons,
// spinners and close marks; 14 for menu rows and marks inline with text; 16 for buttons and compact
// rows; 20 for primary rows; artwork is 24 or larger. A glyph at 9, 10, 11, 13, 15 or 17 reads as two
// marks that should match but sit 1-2 px apart. Leo, 2026-11-01: "the overall shapes/symbols/sizing/
// alignment/system of it all doesn't feel as considered as it could be"; 2026-11-03: "there's just tons
// of design systems related stuff for spacing guttters icons etc whatever like we don't yet feel
// 'designed' yet". cmux#30441 put the sizes on the scale by hand; this keeps them there.
//
// It reads three shapes of icon size under src/:
//   - a JSX `size={N}` prop (lucide icons, StatusGlyph, AgentMark and every icon component take `size`);
//   - an inline `<svg width="N" height="N">` (a square svg is an icon);
//   - a CSS rule whose last selector names an svg, icon, glyph, chevron, spinner or mark and sets
//     `width` and `height` to the same px (a square box is an icon; a 22px button height is not).
// A size under 24 that is not 12, 14, 16 or 20 is a finding, unless its line or the line before says
// `icon-scale-allow: <reason>` (the composer's own 18 glyph set is the named exception). Gallery
// fixtures and prototypes are not product UI and are skipped; so are `::before`/`::after` dots.
//
// Debt that predates the check is in scripts/icon-scale-baseline.tsv (file, px, count). A file may
// not draw more off-scale icons at a size than its row records; `--update-baseline` shrinks rows
// and refuses to grow one, so new debt cannot be recorded as baseline.
// test/check-icon-scale.test.ts runs it; `bun scripts/check-icon-scale.ts` runs it alone.
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, "../src");
const BASELINE = join(HERE, "icon-scale-baseline.tsv");
const SCALE = new Set([12, 14, 16, 20]);
const ARTWORK = 24;
const ALLOW = /icon-scale-allow:\s*\S/;
const ICON_SELECTOR = /(?:svg|icon|glyph|chevron|spinner)(?![\w-]*(?:button|btn))/i;
// A dot drawn by `::before`/`::after` (an unread mark, a bullet) is a shape, not a glyph.
const PSEUDO = /::?(?:before|after)\b/;

/** A selector whose last compound names an svg, icon, glyph, chevron or spinner (not a dot or a button). */
export function isIconSelector(selector: string): boolean {
  const parts = selector.split(",").map(
    (part) =>
      part
        .trim()
        .split(/[\s>+~]+/)
        .pop() ?? "",
  );
  return parts.some((part) => ICON_SELECTOR.test(part) && !PSEUDO.test(part));
}

export type IconFinding = { file: string; line: number; px: number; source: string };

export function offScale(px: number): boolean {
  return px > 0 && px < ARTWORK && !SCALE.has(px);
}

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (["node_modules", "generated", "gallery", "prototype", "prototypes"].includes(entry.name)) return [];
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    if (/\.(?:test|gallery)\.|\.d\.ts$/.test(entry.name)) return [];
    return /\.(?:tsx|css)$/.test(entry.name) ? [path] : [];
  });
}

function allowed(lines: string[], line: number): boolean {
  return ALLOW.test(lines[line - 1] ?? "") || ALLOW.test(lines[line - 2] ?? "");
}

function lineAt(text: string, index: number): number {
  return text.slice(0, index).split("\n").length;
}

/** Off-scale icon sizes in one TSX file's text. */
export function findTsxIcons(file: string, text: string): IconFinding[] {
  const lines = text.split("\n");
  const found: IconFinding[] = [];
  const push = (index: number, px: number, source: string) => {
    const line = lineAt(text, index);
    if (offScale(px) && !allowed(lines, line)) found.push({ file, line, px, source });
  };
  // Only a component's `size` (`<Check size={11}>`); an `<input size={1}>` is a width in characters.
  const sizeProp = /<[A-Z][\w.]*\b[^<>]*?\bsize=\{\s*(\d+(?:\.\d+)?)\s*\}/g;
  for (let m = sizeProp.exec(text); m; m = sizeProp.exec(text)) {
    const at = m[0].lastIndexOf("size=");
    push(m.index + at, Number(m[1]), m[0].slice(at));
  }
  const svgTag = /<svg\b[^>]*>/g;
  for (let m = svgTag.exec(text); m; m = svgTag.exec(text)) {
    const width = /\swidth=\{?"?(\d+(?:\.\d+)?)"?\}?/.exec(m[0]);
    const height = /\sheight=\{?"?(\d+(?:\.\d+)?)"?\}?/.exec(m[0]);
    if (width && height && width[1] === height[1]) push(m.index, Number(width[1]), `<svg ${width[0].trim()}>`);
  }
  return found;
}

/** Off-scale square icon boxes in one stylesheet's text. */
export function findCssIcons(file: string, text: string): IconFinding[] {
  const lines = text.split("\n");
  const found: IconFinding[] = [];
  // Comments go to spaces so offsets (and lines) stay; the allow comment is read from the raw lines.
  const plain = text.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
  const rule = /([^{}]+)\{([^{}]*)\}/g;
  for (let m = rule.exec(plain); m; m = rule.exec(plain)) {
    const selector = m[1]!.trim();
    if (selector.startsWith("@")) continue;
    if (!isIconSelector(selector)) continue;
    const body = m[2]!;
    const width = /(?:^|[;\s])(?:width|inline-size)\s*:\s*(\d+(?:\.\d+)?)px\s*(?:;|$)/.exec(body);
    const height = /(?:^|[;\s])(?:height|block-size)\s*:\s*(\d+(?:\.\d+)?)px\s*(?:;|$)/.exec(body);
    if (!width || !height || width[1] !== height[1]) continue;
    const px = Number(width[1]);
    const bodyStart = m.index + m[0].indexOf("{") + 1;
    const line = lineAt(plain, bodyStart + width.index);
    if (offScale(px) && !allowed(lines, line) && !allowed(lines, lineAt(plain, bodyStart + height.index)))
      found.push({ file, line, px, source: `${selector.replace(/\s+/g, " ").slice(0, 80)} { ${px}px }` });
  }
  return found;
}

/** Every finding under src/. */
export function findAllIcons(srcDir: string = SRC): IconFinding[] {
  return sourceFiles(srcDir).flatMap((path) => {
    const file = relative(srcDir, path);
    const text = readFileSync(path, "utf8");
    return file.endsWith(".css") ? findCssIcons(file, text) : findTsxIcons(file, text);
  });
}

const key = (file: string, px: number) => `${file}\t${px}`;

export function counts(findings: IconFinding[]): Map<string, number> {
  const out = new Map<string, number>();
  for (const f of findings) out.set(key(f.file, f.px), (out.get(key(f.file, f.px)) ?? 0) + 1);
  return out;
}

export function readBaseline(text: string): Map<string, number> {
  const out = new Map<string, number>();
  for (const row of text.split("\n")) {
    if (!row.trim() || row.startsWith("#")) continue;
    const [file, px, count] = row.split("\t");
    out.set(key(file!, Number(px)), Number(count));
  }
  return out;
}

/** Findings over their baseline row, grouped by file and size. */
export function overBaseline(findings: IconFinding[], baseline: Map<string, number>): IconFinding[] {
  const current = counts(findings);
  return findings.filter((f) => (current.get(key(f.file, f.px)) ?? 0) > (baseline.get(key(f.file, f.px)) ?? 0));
}

function renderBaseline(rows: Map<string, number>): string {
  const body = [...rows.entries()]
    .filter(([, count]) => count > 0)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, count]) => `${k}\t${count}`);
  return `# file\tpx\tcount: off-scale icon sizes that predate check-icon-scale.ts. Rows only shrink.\n${body.join("\n")}\n`;
}

if (import.meta.main) {
  const found = findAllIcons();
  const baseline = readBaseline(readFileSync(BASELINE, "utf8"));
  if (process.argv.includes("--update-baseline")) {
    const current = counts(found);
    const grown = [...current].filter(([k, count]) => count > (baseline.get(k) ?? 0));
    if (grown.length) {
      for (const [k, count] of grown)
        console.error(`icon scale: refusing to grow ${k.replace("\t", " @ ")}px to ${count}`);
      process.exit(1);
    }
    writeFileSync(BASELINE, renderBaseline(current));
    console.log("Icon-scale baseline shrunk to the current debt.");
  } else {
    const over = overBaseline(found, baseline);
    for (const f of over)
      console.error(
        `icon scale: ${f.file}:${f.line}: ${f.source} draws an icon at ${f.px}px ` +
          "(icons are 12, 14, 16 or 20, artwork 24+; say icon-scale-allow: <reason> to keep it)",
      );
    const stale = [...baseline].filter(([k, count]) => (counts(found).get(k) ?? 0) < count);
    if (stale.length) console.log(`Icon-scale debt shrank in ${stale.length} row(s); run with --update-baseline.`);
    if (over.length) process.exitCode = 1;
    else console.log("Icon scale checked: no new off-scale icon.");
  }
}
