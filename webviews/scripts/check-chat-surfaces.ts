// One set of chat surface levels (Lawrence 2026-11-19, the edit card nearly clear beside a darker
// error card in one see-through chat: "bgs are different, we need to make all bgs consistent, from
// first principles"). Every fill the chat draws is a level of the design scale
// (schemas/design-scale/design-scale.json `surfaces`, written into desktop.css as --ds-surface-*), a
// state (--ds-color-hover, --ds-color-pressed, --ds-color-selection), a role colour (the accent, a
// status) or the floating glass (glass.css). design/chat-surfaces.md says why.
//
// A raw fill is a background written as a colour of its own: a literal (#hex, rgb(), hsl(), oklch(),
// black, white) or a color-mix() mixed on the spot, in `background`, `background-color` or a custom
// property that names a fill (`--*-bg`, `--*-fill`, `--*-surface`). It fails here, unless its line or
// the line before says why: `/* chat-surface-allow: <reason> */` (a diff's add and delete marks, a
// gallery swatch). Galleries, prototypes and run-board variants are not checked.
//
// The fills that predate the levels are a backlog per file (test/chat-surfaces.baseline.json) that
// only shrinks: a file may hold no more raw fills than its line there, and when it holds fewer the
// line must come down with it. test/chat-surfaces.test.ts runs this in the webviews test lane;
// `bun scripts/check-chat-surfaces.ts` lists every raw fill.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../src");
export const CHAT_ROOT = join(SRC, "agent-session");
const ALLOW = /chat-surface-allow:\s*\S/;
const SKIP_FILE = /\.gallery\.css$/;
const SKIP_DIR = new Set(["node_modules", "prototype", "prototypes", "gallery", "run-board"]);
const FILL_PROPERTY = /^(background|background-color|--[\w-]*-(bg|fill|surface))$/i;
const RAW_COLOR = /#[0-9a-f]{3,8}\b|\b(rgba?|hsla?|oklch|oklab|lab|lch|color-mix)\(|\b(black|white)\b/i;

function* cssFiles(dir: string): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIR.has(entry.name)) yield* cssFiles(full);
    } else if (entry.name.endsWith(".css") && !SKIP_FILE.test(entry.name)) {
      yield full;
    }
  }
}

/// Blanks comments but keeps every newline, so offsets still map to the source's lines.
function blankComments(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, (match) => match.replace(/[^\n]/g, " "));
}

/// `line: property: value` for each raw fill in `css`.
export function rawFillsInCss(css: string): string[] {
  const lines = css.split("\n");
  const text = blankComments(css);
  const out: string[] = [];
  for (const match of text.matchAll(/(--[\w-]+|[a-z-]+)\s*:\s*([^;{}]*)/gi)) {
    const [, property, value] = match as unknown as [string, string, string];
    if (!FILL_PROPERTY.test(property) || !RAW_COLOR.test(value)) continue;
    // A selector such as `a:hover` matches the pattern too; a declaration's value never holds `{`.
    const line = text.slice(0, match.index).split("\n").length - 1;
    if (ALLOW.test(lines[line] ?? "") || ALLOW.test(lines[line - 1] ?? "")) continue;
    out.push(`${line + 1}: ${property}: ${value.trim().replace(/\s+/g, " ")}`);
  }
  return out;
}

/// Raw fills per chat stylesheet, keyed by its path under webviews/src.
export function rawChatFills(): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const file of cssFiles(CHAT_ROOT)) {
    const found = rawFillsInCss(readFileSync(file, "utf8"));
    if (found.length) out[relative(SRC, file)] = found;
  }
  return out;
}

if (import.meta.main) {
  const all = rawChatFills();
  let total = 0;
  for (const [file, found] of Object.entries(all)) {
    total += found.length;
    for (const entry of found) console.log(`${file}:${entry}`);
  }
  console.log(`${total} raw fills in ${Object.keys(all).length} files`);
}
