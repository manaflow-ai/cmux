// Page colors follow the terminal theme (cx-wqn5). Two ways a page ignored it:
// - a `var(--x, #hex)` whose variable no theme sets, so the fixed fallback always painted;
// - text painted a literal white or black, or the page background, which is transparent in a
//   translucent window, so labels on a filled button vanished.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src");
const NATIVE = path.resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources");

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
  (file) => !/\/(gallery|prototype)\//.test(file) && !file.endsWith(".gallery.css"),
);

/** Every custom property a stylesheet, the page scripts or the native theme payloads set. */
function definedVariables(): { names: Set<string>; prefixes: string[] } {
  const names = new Set<string>();
  const prefixes: string[] = [];
  // The gallery sets variables for its fixtures; the app never does.
  const pages = files(SRC, /\.(css|ts|tsx)$/).filter(
    (file) => !/\/(gallery|prototype)\//.test(file) && !/\.gallery\./.test(file),
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

function lines(file: string): Array<{ where: string; text: string }> {
  const rel = path.relative(SRC, file);
  return fs
    .readFileSync(file, "utf8")
    .split("\n")
    .map((text, index) => ({ where: `${rel}:${index + 1}`, text }))
    .filter(({ text }) => !ALLOW.test(text));
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
    expect(unset).toEqual([]);
  });

  test("text never paints literal white or black, or the page background", () => {
    const fixedInk =
      /(?:^|[;{\s])color:\s*(?:#fff\b|#ffffff\b|white\b|#000\b|#000000\b|black\b|var\(--cmux-surface-background\b)/i;
    const found = pageCSS.flatMap((file) =>
      lines(file)
        .filter(({ text }) => fixedInk.test(text))
        .map(({ where, text }) => `${where} ${text.trim()}`),
    );
    expect(found).toEqual([]);
  });
});
