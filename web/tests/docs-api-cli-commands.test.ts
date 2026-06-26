import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Regression guard for https://github.com/manaflow-ai/cmux/issues/5469.
//
// The CLI reference page (web/app/[locale]/docs/api/page.tsx) documented
// commands that do not exist in the CLI — e.g. `cmux list-surfaces`, which
// fails with "Unknown command: list-surfaces". Every `cmux <command>` shown in
// a CLI example must resolve to a real command handled by CLI/cmux.swift,
// otherwise users hit an error when copy-pasting from the docs.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const apiPagePath = join(
  repoRoot,
  "web",
  "app",
  "[locale]",
  "docs",
  "api",
  "page.tsx",
);
const cliSourcePath = join(repoRoot, "CLI", "cmux.swift");

// Real top-level commands are the `case "name":` (and `case "a", "b":`) labels
// in the CLI command dispatch. This intentionally over-approximates (it scans
// every command-shaped case label in the file), which is safe here: the test
// only checks that documented commands are a subset of real commands, so extra
// labels never cause a false failure, while a fictional command like
// `list-surfaces` — which appears as no case label anywhere — is still caught.
function realCommandNames(): Set<string> {
  const swift = readFileSync(cliSourcePath, "utf8");
  const names = new Set<string>();
  const caseRe =
    /case\s+("[a-z][a-z0-9-]*"(?:\s*,\s*"[a-z][a-z0-9-]*")*)\s*:/g;
  for (const match of swift.matchAll(caseRe)) {
    for (const literal of match[1].matchAll(/"([^"]+)"/g)) {
      names.add(literal[1]);
    }
  }
  return names;
}

// Documented commands are the first token of every `cmux <command> ...` line
// inside a `cli={`...`}` prop of the <Cmd> component. Scoping to cli props
// avoids prose and shell snippets (e.g. `echo "cmux available"`).
function documentedCommands(): string[] {
  const page = readFileSync(apiPagePath, "utf8");
  const commands: string[] = [];
  const cliPropRe = /cli=\{`([\s\S]*?)`\}/g;
  for (const match of page.matchAll(cliPropRe)) {
    for (const line of match[1].split(/\r?\n/)) {
      const command = line.trim().match(/^cmux\s+([a-z][a-z0-9-]*)/);
      if (command) {
        commands.push(command[1]);
      }
    }
  }
  return commands;
}

describe("docs/api CLI reference", () => {
  test("every documented `cmux <command>` is a real CLI command", () => {
    const realCommands = realCommandNames();
    const documented = documentedCommands();

    // Sanity check that extraction is actually finding commands.
    expect(documented.length).toBeGreaterThan(0);
    expect(realCommands.has("list-pane-surfaces")).toBe(true);

    const invalid = [...new Set(documented)]
      .filter((command) => !realCommands.has(command))
      .sort();
    expect(invalid).toEqual([]);
  });

  test("surface listing documents the real list-pane-surfaces command", () => {
    const documented = new Set(documentedCommands());
    expect(documented.has("list-pane-surfaces")).toBe(true);
    // The non-existent command from issue #5469 must not come back.
    expect(documented.has("list-surfaces")).toBe(false);
  });
});
