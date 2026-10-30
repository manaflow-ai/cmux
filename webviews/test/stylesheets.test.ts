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
