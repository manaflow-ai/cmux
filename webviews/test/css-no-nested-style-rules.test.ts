// l10n-allow-file: test diagnostics.
// Every webview stylesheet keeps its style rules at the top level (or inside an at-rule): a rule
// whose `}` went missing nests every rule after it under its selector (native CSS nesting), and
// those rules then never match (cmux#37653: a merge left `.cv-agentmsg.cv-received[data-open]
// button.cv-agent-tag.is-open {` open, so every sent-row rule after it in AgentMessageRow.css
// stopped applying, and the file ended in a stray `}`). A nested at-rule (`@starting-style`,
// `@media`) inside a rule is fine; a style rule inside a style rule, or an unbalanced brace, is not.
import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";

const webviews = path.resolve(import.meta.dir, "..");

/// Each style rule nested in another style rule, each `}` with no block to close, and each block
/// never closed, by line. Comments and strings are skipped.
export function nestingFaults(css: string): string[] {
  const source = css.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
  const lineOf = (at: number) => source.slice(0, at).split("\n").length;
  const faults: string[] = [];
  const open: { atRule: boolean; line: number }[] = [];
  let start = 0;
  let quote = "";
  for (let at = 0; at < source.length; at += 1) {
    const char = source[at]!;
    if (quote) {
      if (char === "\\") at += 1;
      else if (char === quote) quote = "";
      continue;
    }
    if (char === '"' || char === "'") quote = char;
    else if (char === "{") {
      const prelude = source.slice(start, at).trim();
      const atRule = prelude.startsWith("@");
      const parent = open.at(-1);
      if (parent && !parent.atRule && !atRule)
        faults.push(`line ${lineOf(at)}: "${prelude.split("\n").at(-1)}" is nested in the rule at line ${parent.line}`);
      open.push({ atRule, line: lineOf(at) });
      start = at + 1;
    } else if (char === "}") {
      if (!open.pop()) faults.push(`line ${lineOf(at)}: a } with no block to close`);
      start = at + 1;
    } else if (char === ";") start = at + 1;
  }
  for (const block of open) faults.push(`line ${block.line}: a { never closed`);
  return faults;
}

test("the scanner finds a rule left open and the stray brace it leaves at the end", () => {
  const css = ".a {\n  color: red;\n.b {\n  color: blue;\n}\n}\n";
  expect(nestingFaults(css)).toEqual(['line 3: ".b" is nested in the rule at line 1']);
  expect(nestingFaults(".a { color: red; }\n}\n")).toEqual(["line 2: a } with no block to close"]);
  expect(nestingFaults(".a { color: red;\n")).toEqual(["line 1: a { never closed"]);
  // Nested at-rules, at-rule blocks, comments and strings are fine.
  expect(
    nestingFaults(
      '.a { opacity: 1; @starting-style { opacity: 0; } }\n@media (x) { .b { content: "{"; } }\n/* .c { */',
    ),
  ).toEqual([]);
});

test("no webview stylesheet nests a style rule in another or leaves a brace unbalanced", () => {
  const files = execFileSync("git", ["ls-files", "src/**/*.css", "src/*.css"], { cwd: webviews, encoding: "utf8" })
    .split("\n")
    .filter(Boolean);
  expect(files).toContain("src/agent-session/acpmux/conversation/AgentMessageRow.css");
  const faults = files.flatMap((file) =>
    nestingFaults(readFileSync(path.join(webviews, file), "utf8")).map((fault) => `${file} ${fault}`),
  );
  expect(faults).toEqual([]);
});
