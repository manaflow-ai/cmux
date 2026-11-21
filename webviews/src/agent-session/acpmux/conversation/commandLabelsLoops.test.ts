// l10n-allow-file: test fixtures (real command lines and the English the rows draw).
// A command row's heading reads loops, variables, compound commands and pipelines (Leo,
// 2026-11-21, on a row that read "Read $f" for a loop over four files: "this is not a good enough
// tool call heading that we have derived"). A loop over named files reads as the files it read, a
// variable reads as its value, and a heading never shows a `$f`; a call's description says what a
// loop or a compound command did before the table does.
import { expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { toolLabel } from "../toolPaths";

const t = translatorFor("en");
let next = 0;

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const tool = (command: string, extra: Partial<Tool> = {}): Tool => ({
  id: `loop-${next++}`,
  title: "Bash",
  kind: "execute",
  status: "completed",
  command,
  ...extra,
});

const label = (call: Tool) =>
  toolLabel(call, "Bash", (command) => t("tools.ranCommand", { command }), undefined, t("tools.ranUnnamed"));

// Leo's row, as the agent ran it.
const LEO =
  `H=$(ls -d ~/.wt/checkouts/cmuxterm-hq/* | head -1); cd "$H"; for f in docs/findings/CLAIMED.md ` +
  `docs/findings/2026-11-21-pool-right-size.md docs/findings/2026-11-21-ci-capacity-sizing.md ` +
  `docs/handbook/hand-set-concurrency-number.md; do echo "=== $f"; git show origin/main:$f | head -30 | cut -c1-240; done`;

test("a loop over files reads as the files it read, never as Read $f", () => {
  expect(label(tool(LEO))).toBe(
    "Read 4 files (CLAIMED.md, 2026-11-21-pool-right-size.md, 2026-11-21-ci-capacity-sizing.md, hand-set-concurrency-number.md)",
  );
  expect(label(tool(`for f in a.ts b.ts; do cat "$f"; done`))).toBe("Read 2 files (a.ts, b.ts)");
  // `for … \n do … \n done` over lines, and `${f}`.
  expect(label(tool("for f in x.md y.md\ndo\n  sed -n '1,20p' \"${f}\"\ndone"))).toBe("Read 2 files (x.md, y.md)");
  // Every pass did the same thing: it reads once.
  expect(label(tool("for i in 1 2 3; do git status --short; done"))).toBe("Checked git status");
});

test("a variable reads as its value; one it cannot read never shows in the heading", () => {
  expect(label(tool(`F=docs/notes.md; cat "$F"`))).toBe("Read notes.md");
  // `$H` came from a `$(…)`, `$OUT` from nowhere, `$f` from a glob: none is named.
  for (const command of [
    `H=$(ls -d ~/x/* | head -1); cat "$H/README.md"`,
    `cat "$OUT"`,
    `for f in *.md; do cat "$f"; done`,
    `while read f; do cat "$f"; done < list.txt`,
  ])
    expect(label(tool(command))).not.toMatch(/^Read .*\$/);
  // Single quotes keep a `$` literal: a search for it is still a search.
  expect(label(tool(`rg -n '$HOME' src`))).toBe("Searched for “$HOME”");
});

test("a pipeline in a loop reads as its first stage over the loop's files", () => {
  expect(label(tool(`for f in a.ts b.ts c.ts; do cat $f | grep -n TODO | head -5; done`))).toBe(
    "Read 3 files (a.ts, b.ts, c.ts)",
  );
});

test("a compound command or a loop with a description reads as the description", () => {
  expect(label(tool(LEO, { description: "Read the claims and sizing notes on hq main" }))).toBe(
    "Read the claims and sizing notes on hq main",
  );
  expect(
    label(tool("git fetch origin && git rebase origin/main && git push", { description: "Rebase and push" })),
  ).toBe("Rebase and push");
  // A single known command still reads as the table names it (#36940).
  expect(label(tool("git status", { description: "Look around" }))).toBe("Checked git status");
});

test("a harness title that kept a shell variable reads as its command", () => {
  // Codex parses `cat $f` in a loop as a read of "$f".
  const codex = tool(`for f in a.md b.md; do cat $f; done`, { title: "Read $f", kind: "read" });
  expect(label(codex)).toBe("Read 2 files (a.md, b.md)");
});
