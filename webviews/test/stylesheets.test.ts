// Every stylesheet closes each rule it opens. A rule left open swallows every rule after it, and
// the build passes: an unclosed `.acpmux-artifact-frame` block unstyled the whole agent page.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const root = join(import.meta.dir, "..", "src");

function stylesheets(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return stylesheets(path);
    return entry.name.endsWith(".css") ? [path] : [];
  });
}

/** The line of the first brace that does not balance, or undefined when every rule closes. */
function unbalanced(css: string): number | undefined {
  const code = css
    .replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "))
    .replace(/"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'/g, (text) => " ".repeat(text.length));
  const open: number[] = [];
  let line = 1;
  for (const char of code) {
    if (char === "\n") line += 1;
    else if (char === "{") open.push(line);
    else if (char === "}" && open.pop() === undefined) return line;
  }
  return open.length > 0 ? open[open.length - 1] : undefined;
}

test("every stylesheet closes the rules it opens", () => {
  const broken = stylesheets(root).flatMap((path) => {
    const line = unbalanced(readFileSync(path, "utf8"));
    return line === undefined ? [] : [`${relative(root, path)}:${line}`];
  });
  expect(broken).toEqual([]);
});

/** The `:has(...)` arguments in a stylesheet's selectors, comments dropped, with their lines. */
function hasArguments(css: string): Array<{ line: number; argument: string }> {
  const code = css.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
  const found: Array<{ line: number; argument: string }> = [];
  for (let at = code.indexOf(":has("); at >= 0; at = code.indexOf(":has(", at + 1)) {
    let depth = 0;
    let end = at + 4;
    for (; end < code.length; end += 1) {
      if (code[end] === "(") depth += 1;
      else if (code[end] === ")" && (depth -= 1) === 0) break;
    }
    found.push({ line: code.slice(0, at).split("\n").length, argument: code.slice(at + 5, end) });
  }
  return found;
}

// Leo, 2026-10-31: "the left scroll rail still lags when i hover over a lot of it it needs to be
// faster". A `[style...]` test inside `:has()` makes Chromium restyle the whole page on every inline
// style write anywhere in it: the running tray's `:has(> ...:not([style*="overflow"]) ...)` cost each
// tick a pointer crossed on the session rail about 16 ms of style work (test/latency/rail-sweep.ts).
// Mark the state with a data attribute instead (conversation/fold.ts `data-fold-clip`).
test("no :has() selector reads the style attribute", () => {
  const found = stylesheets(root).flatMap((path) =>
    hasArguments(readFileSync(path, "utf8"))
      .filter(({ argument }) => /\[\s*style\b/.test(argument))
      .map(({ line }) => `${relative(root, path)}:${line}`),
  );
  expect(found).toEqual([]);
});
