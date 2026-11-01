// Every find folds case through src/find/fold.ts. A find that lowercases on its own drifts: with
// `toLocaleLowerCase` or a bare `toLowerCase` it misses `İ` (U+0130, which lowercases to two
// characters), shifts every highlight after it, and follows the host's locale. This fails such a
// module, and a find module that stops using the shared fold.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

const src = path.resolve(import.meta.dir, "../src");

function sources(dir: string, into: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const file = path.join(dir, name);
    if (statSync(file).isDirectory()) sources(file, into);
    else if (/\.(ts|tsx)$/.test(name) && !/\.(test|gallery)\./.test(name)) into.push(file);
  }
  return into;
}

const relative = (file: string) => path.relative(src, file);
const code = (file: string) =>
  readFileSync(file, "utf8")
    .split("\n")
    // Shortcut keys are not text being searched.
    .filter((line) => !/\bevent\.key\.toLowerCase\(\)/.test(line) && !/^\s*(\/\/|\*|\/\*)/.test(line))
    .join("\n");

/** The modules that search text and report where the match is, or whether it exists. */
const FINDS = [
  "find/model.ts",
  "find/highlight.ts",
  "find/useDiffFind.ts",
  "agent-session/acpmux/changes/diffFind.ts",
  "agent-session/acpmux/conversation/chatFind.ts",
  "pages/markdown/markdownFind.ts",
  "pages/passwords/model.ts",
];

test("every find module folds through find/fold and never lowercases on its own", () => {
  for (const name of FINDS) {
    const text = code(path.join(src, name));
    expect({ name, ownLowercase: /toLocaleLowerCase\(|\.toLowerCase\(\)/.test(text) }).toEqual({
      name,
      ownLowercase: false,
    });
    expect({ name, usesFold: /\bfoldFind\b/.test(text) }).toEqual({ name, usesFold: true });
  }
});

test("a file named for find does not lowercase with toLocaleLowerCase", () => {
  const offenders = sources(src)
    .filter((file) => /find/i.test(path.basename(file)) && relative(file) !== "find/fold.ts")
    .filter((file) => /toLocaleLowerCase\(/.test(code(file)))
    .map(relative);
  expect(offenders).toEqual([]);
});
