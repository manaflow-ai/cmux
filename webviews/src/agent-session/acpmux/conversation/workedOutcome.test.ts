// l10n-allow-file: test fixtures.
// What a closed "Worked for" says in workedLine's arms (workedOutcome.ts), and tool-row-words'
// plain MCP lines (mcpCalls.ts `mcpPlainLine`): counts, failures, the tests' result and a PR, read
// from the calls the fold holds.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import type { Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { workedCountParts, workedOutcome, workedOutcomeParts, workedSentence } from "./workedOutcome";
import { mcpCall, mcpLabel } from "./mcpCalls";

type Unit = { stringUnit: { value: string } };
const catalog = JSON.parse(readFileSync(new URL("../Localizable.xcstrings", import.meta.url), "utf8")) as {
  strings: Record<string, { localizations: { en: Unit | { variations: { plural: Record<string, Unit> } } } }>;
};
const english = new Intl.PluralRules("en");
const t = ((key: string, values?: Record<string, string | number>) => {
  const en = catalog.strings[key]!.localizations.en;
  const unit = "variations" in en ? en.variations.plural[english.select(Number(values?.n ?? 0))]! : en;
  return unit.stringUnit.value.replace(/\{(\w+)\}/g, (_, name: string) => String(values?.[name]));
}) as Translate;

let next = 0;
type Fields = Partial<NonNullable<AcpmuxActivity["tool"]>>;
const call = (kind: string, fields: Fields = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "Step",
  tool: { id: `c${next++}`, title: "Step", kind, status: "completed", ...fields },
});
const ran = (command: string, exitCode = 0, output?: string) =>
  call("execute", {
    title: command,
    command,
    exitCode,
    status: exitCode ? "failed" : "completed",
    ...(output && { output }),
  });
const edit = (path: string) => call("edit", { title: `Edit ${path}`, diffs: [{ path, oldText: "a", newText: "b" }] });
const text = (parts: { text: string }[]) => parts.map((part) => part.text).join(" · ");

const landed = [
  call("read", { locations: [{ path: "src/a.ts" }] }),
  edit("src/a.ts"),
  edit("src/b.ts"),
  ran("bun test src", 1),
  edit("src/b.ts"),
  ran("bun test src"),
  ran("git push"),
  ran("gh pr create --fill", 0, "https://github.com/acme/web/pull/482\n"),
];
const stuck = [edit("src/c.ts"), ran("bunx vp lint", 2), ran("bun test src", 1)];

test("counts commands and the distinct files edited", () => {
  expect(workedOutcome(landed)).toEqual({
    commands: 4,
    files: 2,
    failed: 0,
    tests: "passed",
    pr: { n: 482, merged: false },
  });
  expect(text(workedCountParts(t, workedOutcome(landed)))).toBe("4 commands · 2 files");
});

test("the last test run is the tests' result, and an earlier failing run is not a failure", () => {
  expect(text(workedOutcomeParts(t, landed))).toBe("Edited 2 files and ran 4 commands · tests passed · opened PR #482");
});

test("failures and failing tests are failure parts", () => {
  const parts = workedOutcomeParts(t, stuck);
  expect(text(parts)).toBe("Edited a file and ran 2 commands · 1 failed · tests failed");
  expect(parts.filter((part) => part.failed).map((part) => part.text)).toEqual(["1 failed", "tests failed"]);
});

test("the sentence arm names the work then how it came out", () => {
  const sentence = workedSentence(t, stuck)!;
  expect(sentence.work).toBe("Edited a file and ran 2 commands");
  expect(sentence.results.map((part) => part.text)).toEqual(["1 failed", "tests failed"]);
  expect(workedSentence(t, [])).toBeUndefined();
});

test("a merge names the PR it merged; a failed gh names none", () => {
  const merged = ran("gh pr merge 77 --squash", 0, "Merged https://github.com/acme/web/pull/77\n");
  expect(workedOutcome([merged]).pr).toEqual({ n: 77, merged: true });
  expect(workedOutcome([ran("gh pr create", 1, "https://github.com/acme/web/pull/9")]).pr).toBeUndefined();
});

afterEach(() => {
  delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
});

const mcp = (name: string, args: unknown) =>
  mcpCall(call("other", { title: name, inputSummary: JSON.stringify(args) }).tool!)!;

test("tool-row-words: plain verbs by default, Claude Code's words on its now arm", () => {
  const grep = mcp("mcp__repo__repo_grep", { pattern: "retry" });
  const blame = mcp("mcp__repo__repo_blame", { path: "src/App.tsx" });
  const bare = mcp("mcp__linear__linear", {});
  const send = mcp("mcp__slack__send_message", { to: "Leo" });
  globalThis.cmuxExperiments = { "tool-row-words": "now" };
  expect(mcpLabel(t, [grep], new Map())).toBe("Used repo: repo grep");
  globalThis.cmuxExperiments = {};
  expect(mcpLabel(t, [grep], new Map())).toBe("Searched repo for “retry”");
  expect(mcpLabel(t, [grep, grep], new Map())).toBe("Searched repo for “retry” ×2");
  expect(mcpLabel(t, [blame], new Map())).toBe("Used repo: blame src/App.tsx");
  expect(mcpLabel(t, [bare], new Map())).toBe("Used linear");
  // A call in flight keeps its words; a tool that starts with a verb keeps today's line.
  expect(mcpLabel(t, [grep], new Map(), true)).toBe("Using repo: repo grep");
  expect(mcpLabel(t, [send], new Map())).toBe(mcpLabelOff(send));
});

function mcpLabelOff(call: NonNullable<ReturnType<typeof mcpCall>>): string {
  const arms = globalThis.cmuxExperiments;
  globalThis.cmuxExperiments = { "tool-row-words": "now" };
  const line = mcpLabel(t, [call], new Map());
  globalThis.cmuxExperiments = arms;
  return line;
}
