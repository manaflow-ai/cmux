// Every stylesheet under src closes each block it opens. The agent pane's build concatenates its
// stylesheets into one, so an unclosed rule in one file swallows every rule after it, and Vite
// refuses the file ("Missing closing }"); a merge that dropped a shared `}` did that (#19473).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src");

function stylesheets(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "node_modules" ? [] : stylesheets(full);
    return entry.name.endsWith(".css") ? [full] : [];
  });
}

/// Where the braces stop balancing: the line of an extra `}`, or the line of the last open block.
function unbalanced(css: string): number | undefined {
  // Comments and strings may hold braces of their own.
  const code = css.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
  const open: number[] = [];
  let line = 1;
  let quote: string | undefined;
  for (let i = 0; i < code.length; i++) {
    const char = code[i]!;
    if (char === "\n") line++;
    if (quote) {
      if (char === "\\") i++;
      else if (char === quote) quote = undefined;
    } else if (char === '"' || char === "'") quote = char;
    else if (char === "{") open.push(line);
    else if (char === "}" && open.pop() === undefined) return line;
  }
  return open.at(-1);
}

test("every stylesheet closes each block it opens", () => {
  const broken = stylesheets(SRC).flatMap((file) => {
    const line = unbalanced(fs.readFileSync(file, "utf8"));
    return line === undefined ? [] : [`${path.relative(SRC, file)}:${line}`];
  });
  expect(broken).toEqual([]);
});
