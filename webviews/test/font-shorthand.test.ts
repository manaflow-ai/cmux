// A `font` shorthand needs a size: without one the browser drops the whole declaration, so the page
// fell back to WebKit's 16px default (the Activity page rendered in 16px Times). Set the family
// alone with `font-family`; desktop.css already gives every page the system family.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src");

function files(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return /^(gallery|prototype)$/.test(entry.name) ? [] : files(full);
    return entry.name.endsWith(".css") ? [full] : [];
  });
}

/**
 * A size token: a length or percentage, a `--text-*` size or a scoped alias of one (galleries name
 * theirs `--bg-text-body: var(--text-body, 13px)`), or a keyword or system font.
 */
const SIZED = /\d(?:px|rem|em|pt|%)|var\(--(?:[a-z0-9]+-)*text-|\b(?:x*-?small|medium|x*-?large|smaller|larger)\b(?!-)/;
const WHOLE = /^(?:inherit|initial|unset|revert|caption|icon|menu|message-box|small-caption|status-bar|var\([^)]*\))$/;

test("every font shorthand on a page names a size", () => {
  const found = files(SRC).flatMap((file) =>
    fs
      .readFileSync(file, "utf8")
      .replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "))
      .split("\n")
      .flatMap((line, index) =>
        [...line.matchAll(/(?:^|[;{\s])font:\s*([^;}]+)/g)]
          .map((match) => match[1].trim())
          .filter((value) => !WHOLE.test(value) && !SIZED.test(value))
          .map((value) => `${path.relative(SRC, file)}:${index + 1} font: ${value}`),
      ),
  );
  expect(found).toEqual([]);
});
