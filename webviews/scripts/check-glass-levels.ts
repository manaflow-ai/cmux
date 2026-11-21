// One set of glass levels (Leo 2026-11-06: "we have, like, a ton of varying glassiness on stuff for
// some reason"). Every glass surface in webviews/src frosts what is behind it through a level of the
// design scale (schemas/design-scale/design-scale.json `glass`, written into desktop.css as
// --ds-glass-<level>-*): chrome, popover, menu or chip, or the lens and fisheye modes. A raw blur
// (`backdrop-filter: blur(18px) saturate(1.08)`, `--my-frost: blur(24px)`, `--my-blur: 6px`) is a
// new glassiness of its own, so this check fails one:
//
// - a declaration whose value has `blur(<number>)` other than blur(0), unless the property is
//   `filter` (an element's own blur, a reveal animation, is not glass);
// - a custom property named `*blur*` or `*frost*` whose value is a bare nonzero length.
//
// `blur(var(--ds-glass-chrome-radius))` passes: the radius is the level's. A blur that is not a glass
// surface (a scrim's softening, a scroll edge's fade, the lens shader's own frost) says why on its
// line or the line before: `/* glass-raw-blur-allow: <reason> */`. Tests, gallery entries and
// fixtures, and prototypes are not checked: a gallery shows candidates beside the level.
// test/glass-levels.test.ts runs this in the webviews test lane; `bun scripts/check-glass-levels.ts`
// runs it alone.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../src");
const ALLOW = /glass-raw-blur-allow:\s*\S/;
const SKIP_FILE = /\.(test|gallery)\.[cm]?[jt]sx?$|\.gallery\.css$/;
const SKIP_DIR = new Set(["node_modules", "prototypes", "prototype", "gallery"]);
const GENERATED = /design-scale:begin[\s\S]*?design-scale:end/;
// blur( then a literal number that is not zero.
const RAW_BLUR = /\bblur\(\s*(?!0(?:px)?\s*\))[\d.]/;
const BARE_LENGTH = /^\s*(?!0(?:px)?\s*$)[\d.]+(px|rem|em)\s*$/;
// In script: a backdrop filter written as a string.
const SCRIPT_RAW = /(backdrop-filter|backdropFilter)["'`]?\s*[:,=]\s*["'`]?[^"'`;\n]*\bblur\(\s*(?!0(?:px)?\s*\))[\d.]/;

function* files(dir: string): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIR.has(entry.name)) yield* files(full);
    } else if (/\.(css|tsx?)$/.test(entry.name) && !SKIP_FILE.test(entry.name)) {
      yield full;
    }
  }
}

/// Blanks comments (and the generated design-scale block, the levels themselves) but keeps every
/// newline, so offsets still map to the source's lines.
function blank(text: string, pattern: RegExp): string {
  return text.replace(pattern, (match) => match.replace(/[^\n]/g, " "));
}

function allowed(lines: string[], line: number): boolean {
  return ALLOW.test(lines[line] ?? "") || ALLOW.test(lines[line - 1] ?? "");
}

/// `file:line: declaration` for each raw blur in `css`.
export function rawBlursInCss(css: string, file: string): string[] {
  const lines = css.split("\n");
  const text = blank(blank(css, GENERATED), /\/\*[\s\S]*?\*\//g);
  const out: string[] = [];
  for (const match of text.matchAll(/(--[\w-]+|[a-z-]+)\s*:\s*([^;{}]*)/gi)) {
    const [, property, value] = match as unknown as [string, string, string];
    if (property === "filter") continue;
    const raw =
      RAW_BLUR.test(value) || (property.startsWith("--") && /blur|frost/i.test(property) && BARE_LENGTH.test(value));
    if (!raw) continue;
    const line = text.slice(0, match.index).split("\n").length - 1;
    if (allowed(lines, line)) continue;
    out.push(`${file}:${line + 1}: ${property}: ${value.trim()}`);
  }
  return out;
}

/// `file:line: text` for each backdrop filter a script writes as a raw blur string.
export function rawBlursInScript(source: string, file: string): string[] {
  const lines = source.split("\n");
  const out: string[] = [];
  lines.forEach((text, line) => {
    if (SCRIPT_RAW.test(text) && !allowed(lines, line)) out.push(`${file}:${line + 1}: ${text.trim()}`);
  });
  return out;
}

// The native side (Packages/macOS/CmuxNext/Sources): a glass view is built by the glass's own files
// (Glass.makePanel / makeOverlayPanel / makeSurface, the window's material), tinted at a GlassLevel.
// Anywhere else a new NSVisualEffectView, NSGlassEffectView, GlassPanelView or SwiftUI .glassEffect,
// or a glass tint whose alpha is scaled by a literal, is a glassiness of its own. A view that is not
// a level (a system control's untinted glass, a setting's look, a Debug fixture) says why on its line:
// `// glass-level-allow: <reason>`.
const SWIFT_SOURCES = join(dirname(fileURLToPath(import.meta.url)), "../../Packages/macOS/CmuxNext/Sources");
const NATIVE_ALLOW = /glass-level-allow:\s*\S/;
const GLASS_BUILDERS = new Set([
  "CmuxNextDesign/Glass.swift",
  "CmuxNextDesign/GlassPanelView.swift",
  "CmuxNextDesign/OverlaySurface.swift",
  "CmuxNextDesign/WindowMaterialView.swift",
  "CmuxNextDesign/FloatingGlass/GlassLevel.swift",
]);
const NATIVE_RAW = /\b(NSVisualEffectView|NSGlassEffectView|GlassPanelView)\(|\.glassEffect\(/;
const TINT_SCALE = /tint\w*\.alphaComponent\s*\*\s*[\d.]/i;

function* swiftFiles(dir: string): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) yield* swiftFiles(full);
    else if (entry.name.endsWith(".swift")) yield full;
  }
}

/// `file:line: text` for each native glass view or tint scale in `source` outside the levels.
export function rawNativeGlass(source: string, file: string): string[] {
  if (GLASS_BUILDERS.has(file)) return [];
  const out: string[] = [];
  source.split("\n").forEach((text, line) => {
    if (/^\s*\/\//.test(text) || NATIVE_ALLOW.test(text)) return;
    const code = text.split("//", 1)[0]!;
    if (NATIVE_RAW.test(code) || TINT_SCALE.test(code)) out.push(`${file}:${line + 1}: ${text.trim()}`);
  });
  return out;
}

/// Every native glass view or tint scale outside the levels under `root` (the CmuxNext sources).
export function findRawNativeGlass(root = SWIFT_SOURCES): string[] {
  const out: string[] = [];
  for (const full of swiftFiles(root)) out.push(...rawNativeGlass(readFileSync(full, "utf8"), relative(root, full)));
  return out;
}

/// Every raw blur under `root` (webviews/src by default).
export function findRawBlurs(root = SRC): string[] {
  const out: string[] = [];
  for (const full of files(root)) {
    const file = relative(root, full);
    const text = readFileSync(full, "utf8");
    out.push(...(full.endsWith(".css") ? rawBlursInCss(text, file) : rawBlursInScript(text, file)));
  }
  return out;
}

if (import.meta.main) {
  const found = [...findRawBlurs(), ...findRawNativeGlass()];
  if (found.length > 0) {
    console.error(
      "A raw blur outside the glass levels (design-scale glass: chrome, popover, menu, chip). Name a level " +
        "(var(--ds-glass-<level>-blur), or blur(var(--ds-glass-<level>-radius))), or say why it is not glass " +
        "with /* glass-raw-blur-allow: <reason> */ (Swift: Glass.makePanel(level:), GlassLevel, or // glass-level-allow: <reason>):",
    );
    for (const line of found) console.error(`  ${line}`);
    process.exit(1);
  }
  console.log("check-glass-levels: every blur names a glass level");
}
