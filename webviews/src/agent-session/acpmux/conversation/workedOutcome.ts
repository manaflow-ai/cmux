// What a finished turn did and how it came out, for its closed "Worked for" line
// (workedLine.experiment.ts): counts of commands and changed files, the calls that failed, the
// tests' result and a pull request it opened or merged. Read from the calls the fold already holds
// (`workedRuns`): no model call, one pass over the turn's calls.
import type { Translate } from "../i18n";
import { pathKey, toolCanonical, type AcpmuxActivity } from "../model";
import { toolKind } from "../toolNames";
import { countsFailed } from "./toolGroups";
import { toolRunCategory, toolRunSummary } from "./toolRunSummary";
import { mcpCall } from "./mcpCalls";
import { editedPaths } from "../toolPaths";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type WorkedOutcome = {
  commands: number;
  /// Distinct files the turn's edits changed.
  files: number;
  /// Calls that failed, the test runs among them left out (`tests` names those).
  failed: number;
  /// The last test run's result.
  tests?: "passed" | "failed";
  /// The last pull request a `gh pr create` or `gh pr merge` named in its output.
  pr?: { n: number; merged: boolean };
};

/// A command that runs a test suite.
const TEST_COMMAND =
  /\b(?:(?:bun|npm|pnpm|yarn|deno|cargo|go|swift|make|mix|dotnet)\s+(?:run\s+)?test\b|pytest\b|vitest\b|jest\b|rspec\b|xcodebuild\b[^\n]*\btest\b)/;
const PR_COMMAND = /\bgh\s+pr\s+(create|merge)\b/;
const PR_URL = /github\.com\/[\w.-]+\/[\w.-]+\/pull\/(\d+)/;
/// Outputs past this are not searched for a pull request's address: the label stays cheap.
const PR_OUTPUT_MAX = 16_000;

const commandOf = (tool: Tool) => tool.command ?? (toolKind(tool) === "execute" ? tool.title : "");

/// The outcome of a turn's calls.
export function workedOutcome(items: readonly AcpmuxActivity[]): WorkedOutcome {
  let commands = 0;
  let failed = 0;
  let tests: WorkedOutcome["tests"];
  let pr: WorkedOutcome["pr"];
  const files = new Set<string>();
  let unnamedEdits = 0;
  for (const { tool } of items) {
    if (!tool) continue;
    const category = mcpCall(tool) ? "used" : toolRunCategory(toolKind(tool));
    const command = commandOf(tool);
    const test = category === "ran" && TEST_COMMAND.test(command);
    if (category === "ran") commands += 1;
    if (category === "edited") {
      const named = tool.diffs?.length
        ? [...tool.diffs, ...(tool.locations ?? [])].map(pathKey)
        : editedPaths(tool).map((path) => toolCanonical(tool, path) ?? path);
      if (!named.length) unnamedEdits += 1;
      for (const path of named) files.add(path);
    }
    if (test && tool.status !== "pending" && tool.status !== "in_progress")
      tests = countsFailed(tool) ? "failed" : "passed";
    else if (countsFailed(tool)) failed += 1;
    const prCommand = category === "ran" ? PR_COMMAND.exec(command) : null;
    if (prCommand && !countsFailed(tool) && tool.output && tool.output.length <= PR_OUTPUT_MAX) {
      const url = PR_URL.exec(tool.output) ?? PR_URL.exec(command);
      if (url) pr = { n: Number(url[1]), merged: prCommand[1] === "merge" };
    }
  }
  return { commands, files: files.size + unnamedEdits, failed, ...(tests && { tests }), ...(pr && { pr }) };
}

/// One part of the line: its words, and whether it is a failure (drawn in the failure red).
export type WorkedPart = { text: string; failed?: boolean };

/// The `counts` arm: "4 commands · 2 files", or nothing when the turn ran and changed nothing.
export function workedCountParts(t: Translate, outcome: WorkedOutcome): WorkedPart[] {
  const parts: WorkedPart[] = [];
  if (outcome.commands)
    parts.push({
      text:
        outcome.commands === 1 ? t("workedLine.commands.one") : t("workedLine.commands.other", { n: outcome.commands }),
    });
  if (outcome.files)
    parts.push({
      text: outcome.files === 1 ? t("workedLine.files.one") : t("workedLine.files.other", { n: outcome.files }),
    });
  return parts;
}

/// How the turn came out: "2 failed", "tests failed", "opened PR #482", in that order.
export function workedResultParts(t: Translate, outcome: WorkedOutcome): WorkedPart[] {
  const parts: WorkedPart[] = [];
  if (outcome.failed) parts.push({ text: t("tools.failedCount", { n: outcome.failed }), failed: true });
  if (outcome.tests === "failed") parts.push({ text: t("workedLine.testsFailed"), failed: true });
  if (outcome.tests === "passed") parts.push({ text: t("workedLine.testsPassed") });
  if (outcome.pr)
    parts.push({
      text: outcome.pr.merged
        ? t("workedLine.prMerged", { n: outcome.pr.n })
        : t("workedLine.prOpened", { n: outcome.pr.n }),
    });
  return parts;
}

/// What the turn did, as a sentence of its edits and commands ("Edited 2 files and ran 4 commands"):
/// reads and searches are steps, not outcomes. A turn that edited and ran nothing reads as its run's
/// own sentence ("Read 6 files").
function workedWork(t: Translate, items: readonly AcpmuxActivity[], outcome: WorkedOutcome): string {
  const phrases = [
    ...(outcome.files
      ? [outcome.files === 1 ? t("toolRun.edited.one") : t("toolRun.edited.other", { n: outcome.files })]
      : []),
    ...(outcome.commands
      ? [outcome.commands === 1 ? t("toolRun.ran.one") : t("toolRun.ran.other", { n: outcome.commands })]
      : []),
  ];
  if (!phrases.length) return toolRunSummary(t, items);
  const text = phrases.join(t("toolRun.and"));
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/// The `outcome` arm: what the turn did ("Edited 2 files and ran 4 commands"), then how it came out.
export function workedOutcomeParts(t: Translate, items: readonly AcpmuxActivity[]): WorkedPart[] {
  if (!items.some((item) => item.tool)) return [];
  const outcome = workedOutcome(items);
  return [{ text: workedWork(t, items, outcome) }, ...workedResultParts(t, outcome)];
}

/// The `sentence` arm's words before the time: "Edited 2 files and ran 4 commands: tests failed",
/// or undefined when the turn made no call.
export function workedSentence(
  t: Translate,
  items: readonly AcpmuxActivity[],
): { work: string; results: WorkedPart[] } | undefined {
  if (!items.some((item) => item.tool)) return undefined;
  const outcome = workedOutcome(items);
  return { work: workedWork(t, items, outcome), results: workedResultParts(t, outcome) };
}
