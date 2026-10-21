// Page colors follow the terminal theme (cx-wqn5). Ways a page ignored it:
// - a `var(--x, #hex)` whose variable no theme sets, so the fixed fallback always painted;
// - text painted a literal white or black, or the page background, which is transparent in a
//   translucent window, so labels on a filled button vanished;
// - an element filled or ringed with that clear page background (a pill over a rule, an avatar's
//   cut-out ring), so it vanished over a see-through window;
// - a ring, pill or glyph in the theme's surface token, which is translucent in a see-through
//   window, instead of the opaque page color;
// - a literal color (a fixed yellow find highlight, a white popup edge). Files not yet migrated
//   are listed in theme-colors.pending.json with their count, which may only go down.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import pendingFile from "./theme-colors.pending.json";
import { prScope } from "./support/prScope";

const SRC = path.resolve(import.meta.dir, "../src");
const NATIVE = path.resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources");

// This ratchet scans every shipped page stylesheet. Keep inherited findings visible on a pull
// request, but make a finding fail only when its source file (or the pending list/check itself)
// belongs to the change. Base pushes and local runs still check every finding.
const scope = prScope({
  rules: ["webviews/test/theme-colors.test.ts", "webviews/test/support/prScope.ts"],
  lists: ["webviews/test/theme-colors.pending.json"],
});

const at = (file: string) => ({ files: [`webviews/src/${file}`], names: [file] });
const findingFile = (finding: string) => finding.slice(0, finding.indexOf(":"));
const owned = (findings: readonly string[]) =>
  scope.owned(
    findings,
    (finding) => at(findingFile(finding)),
    (finding) => finding,
  );

/** A line marked `theme-fixed: <reason>` keeps its literal color (e.g. white on a media scrim). */
const ALLOW = /theme-fixed:\s*\S/;

function files(dir: string, ext: RegExp): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...files(full, ext));
    else if (ext.test(entry.name)) out.push(full);
  }
  return out;
}

/** Page stylesheets: gallery fixtures and prototypes never ship. */
const pageCSS = files(SRC, /\.css$/).filter(
  (file) => !/\/(gallery|prototypes?)\//.test(file) && !file.endsWith(".gallery.css"),
);

/** Every custom property a stylesheet, the page scripts or the native theme payloads set. */
function definedVariables(): { names: Set<string>; prefixes: string[] } {
  const names = new Set<string>();
  const prefixes: string[] = [];
  // The gallery sets variables for its fixtures; the app never does.
  const pages = files(SRC, /\.(css|ts|tsx)$/).filter(
    (file) => !/\/(gallery|prototypes?)\//.test(file) && !/\.gallery\./.test(file),
  );
  const sources = [...pages, ...files(NATIVE, /\.swift$/)];
  for (const file of sources) {
    const text = fs.readFileSync(file, "utf8");
    for (const match of text.matchAll(/(--[\w-]+)\s*:/g)) names.add(match[1]);
    for (const match of text.matchAll(/["'`](--[\w-]+)/g)) names.add(match[1]);
    for (const match of text.matchAll(/(--[\w-]+-)\$\{/g)) prefixes.push(match[1]);
  }
  return { names, prefixes };
}

/** The file's lines, comments blanked (a comment may name the color it replaced), without the
 *  lines marked `theme-fixed`. */
function lines(file: string): Array<{ where: string; text: string }> {
  const rel = path.relative(SRC, file);
  const raw = fs.readFileSync(file, "utf8");
  const marked = raw.split("\n").map((text) => ALLOW.test(text));
  return raw
    .replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "))
    .split("\n")
    .map((text, index) => ({ where: `${rel}:${index + 1}`, text }))
    .filter((_, index) => !marked[index]);
}

/** `text` without each `var(--x, fallback)`, up to its own closing parenthesis. */
function withoutFallbacks(text: string): string {
  let out = "";
  let index = 0;
  for (const match of text.matchAll(/var\(--[\w-]+\s*,/g)) {
    if (match.index! < index) continue;
    out += text.slice(index, match.index);
    let depth = 1;
    let end = match.index! + match[0].length;
    while (end < text.length && depth > 0) {
      if (text[end] === "(") depth++;
      else if (text[end] === ")") depth--;
      end++;
    }
    index = end;
  }
  return out + text.slice(index);
}

/** A literal color that is not a black shade (shadows and scrims darken in every theme), outside
 *  a `var()` fallback (the first rule checks those). */
function literalColor(text: string): boolean {
  const outsideFallbacks = withoutFallbacks(text);
  return /#(?!(?:000|000000)\b)[0-9a-f]{3,8}\b|\brgba?\((?!\s*0[\s,]+0[\s,]+0\b)|\bhsla?\(|(?<![\w-])white(?![\w-])/i.test(
    outsideFallbacks,
  );
}

describe("page colors follow the theme", () => {
  test("a fixed fallback color only backs a variable some theme sets", () => {
    const { names, prefixes } = definedVariables();
    const fallback = /var\((--[\w-]+)\s*,\s*(?:#[0-9a-f]{3,8}\b|rgba?\(|light-dark\(|white\b|black\b|Canvas)/gi;
    const unset = pageCSS.flatMap((file) =>
      lines(file).flatMap(({ where, text }) =>
        [...text.matchAll(fallback)]
          .map((match) => match[1])
          .filter((name) => !names.has(name) && !prefixes.some((prefix) => name.startsWith(prefix)))
          .map((name) => `${where} ${name}`),
      ),
    );
    expect(owned(unset)).toEqual([]);
  });

  test("text never paints literal white or black, or the page background", () => {
    const fixedInk =
      /(?:^|[;{\s])color:\s*(?:#fff\b|#ffffff\b|white\b|#000\b|#000000\b|black\b|var\(--cmux-surface-background\b)/i;
    const found = pageCSS.flatMap((file) =>
      lines(file)
        .filter(({ text }) => fixedInk.test(text))
        .map(({ where, text }) => `${where} ${text.trim()}`),
    );
    expect(owned(found)).toEqual([]);
  });

  test("an element never fills or rings itself with the clear page background", () => {
    // The page's own background (`html`, a root alias) may read it; an element takes the opaque
    // page color (`--cmux-surface-solid`).
    const pageFill = /^\s*background:\s*var\(--cmux-surface-background,\s*transparent\)/;
    const alias = /^\s*--[\w-]+:\s*var\(--cmux-surface-background\b/;
    const found = pageCSS.flatMap((file) =>
      lines(file)
        .filter(({ text }) => /var\(--cmux-surface-background\b/.test(text))
        .filter(({ text }) => !pageFill.test(text) && !alias.test(text))
        .map(({ where, text }) => `${where} ${text.trim()}`),
    );
    expect(owned(found)).toEqual([]);
  });

  test("a ring, pill or glyph on a fill takes the opaque page color", () => {
    // `--cmux-surface-token` carries the theme's background-opacity and ignores a page's own
    // background, so a ring over a rule let the rule through; `--cmux-surface-solid` is opaque.
    const found = pageCSS.flatMap((file) =>
      lines(file)
        .filter(({ text }) => /var\(--cmux-surface-token\b/.test(text))
        .map(({ where, text }) => `${where} ${text.trim()}`),
    );
    expect(owned(found)).toEqual([]);
  });

  describe("literal colors only go down", () => {
    const { "//": _note, ...pending } = pendingFile as Record<string, string | number>;
    const actual: Record<string, number> = {};
    const fresh: string[] = [];
    for (const file of pageCSS) {
      const rel = path.relative(SRC, file);
      const hits = lines(file).filter(({ text }) => literalColor(text));
      if (hits.length) actual[rel] = hits.length;
      if (!(rel in pending)) fresh.push(...hits.map(({ where, text }) => `${where} ${text.trim()}`));
    }

    test("a migrated stylesheet takes its colors from the theme", () => {
      expect(owned(fresh)).toEqual([]);
    });

    test("a pending stylesheet never gains literal colors", () => {
      const grown = Object.entries(actual).filter(([file, count]) => file in pending && count > Number(pending[file]));
      expect(
        scope.owned(
          grown,
          ([file]) => at(file),
          ([file, count]) => `${file}: ${count} > ${pending[file]}`,
        ),
      ).toEqual([]);
    });

    test("the pending list shrinks with the migration (lower a count, delete a clean file)", () => {
      const stale = Object.entries(pending).filter(([file, count]) => (actual[file] ?? 0) < Number(count));
      expect(
        scope.owned(
          stale,
          ([file]) => at(file),
          ([file, count]) => `${file}: ${actual[file] ?? 0} < ${count}`,
        ),
      ).toEqual([]);
    });
  });
});
