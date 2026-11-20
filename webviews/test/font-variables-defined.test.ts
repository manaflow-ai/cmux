// A font family read from a custom property that no sheet defines is invalid at computed-value
// time: the declaration falls back to the inherited face (and a `font` shorthand also drops its
// size). The agent pane's mono text (permission commands, preview addresses, replay clock,
// Session Info) read `--font-mono`, which only Tailwind's theme layer happened to emit because a
// source file named it. Every variable a page's font reads must be defined in our own sheets or
// set by the host or page script, or carry a fallback.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src");

function walk(dir: string, ext: RegExp): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return /^(gallery|prototype|node_modules)$/.test(entry.name) ? [] : walk(full, ext);
    return ext.test(entry.name) && !/\.(test|gallery)\./.test(entry.name) ? [full] : [];
  });
}

const strip = (text: string) => text.replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, " "));
const sheets = walk(SRC, /\.css$/).map((file) => ({ file, text: strip(fs.readFileSync(file, "utf8")) }));
const scripts = walk(SRC, /\.tsx?$/).map((file) => fs.readFileSync(file, "utf8"));

const defined = new Set<string>();
for (const { text } of sheets) for (const m of text.matchAll(/(--[\w-]+)\s*:/g)) defined.add(m[1]);
// Set from script: setProperty("--x", …), or a `"--x":` style key.
for (const text of scripts) {
  for (const m of text.matchAll(/setProperty\(\s*["'`](--[\w-]+)["'`]|["'`](--[\w-]+)["'`]\s*:/g))
    defined.add(m[1] ?? m[2]);
}

test("every variable a font declaration reads is defined or has a fallback", () => {
  const missing: string[] = [];
  for (const { file, text } of sheets) {
    text.split("\n").forEach((line, index) => {
      for (const decl of line.matchAll(/(?:^|[;{\s])font(?:-family)?\s*:\s*([^;}]+)/g)) {
        for (const use of decl[1].matchAll(/var\(\s*(--[\w-]+)\s*(,)?/g)) {
          if (!use[2] && !defined.has(use[1])) missing.push(`${path.relative(SRC, file)}:${index + 1} ${use[1]}`);
        }
      }
    });
  }
  expect(missing).toEqual([]);
});
