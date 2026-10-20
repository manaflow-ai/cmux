import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { toolGroups } from "./toolGroups";
import { shouldFoldToolRun } from "./TurnRows";

const command = (id: string, text: string): AcpmuxActivity => ({
  kind: "tool",
  text,
  tool: { id, title: "Shell", kind: "execute", status: "completed", command: text },
});

const message = (id: string): AcpmuxActivity => ({
  kind: "tool",
  text: "Sent message to coordinator",
  tool: {
    id,
    title: "cmux send",
    kind: "execute",
    status: "completed",
    command: "cmux send --to coordinator --message done",
  },
});

const row = (items: AcpmuxActivity[], flags: Partial<AcpmuxRow> = { settled: true }): AcpmuxRow => ({
  id: "activity",
  version: 1,
  at: 1,
  kind: "activity",
  ...flags,
  items,
});

const reads: AcpmuxActivity[] = [
  command("one", "bun test one"),
  { kind: "tool", text: "Read config", tool: { id: "read", title: "Read", kind: "read", status: "completed" } },
];

test("folds a live turn's settled run made only of tool groups", () => {
  expect(toolGroups(reads)).toHaveLength(2);
  expect(shouldFoldToolRun(row(reads, { foldRun: true }), toolGroups(reads), reads)).toBe(true);
});

test("an open Worked for lists a run's every step unless its Debug toggle folds it", () => {
  const html = { dataset: {} as Record<string, string> };
  const scope = globalThis as { document?: unknown };
  const saved = scope.document;
  scope.document = { documentElement: html };
  try {
    expect(shouldFoldToolRun(row(reads), toolGroups(reads), reads)).toBe(false);
    html.dataset.workedForRuns = "fold";
    expect(shouldFoldToolRun(row(reads), toolGroups(reads), reads)).toBe(true);
  } finally {
    scope.document = saved;
  }
});

test("keeps a coordination message visible beside settled tool calls", () => {
  const items = [message("message"), command("command", "bun test")];
  const groups = toolGroups(items);
  expect(groups.some((group) => group.type === "message")).toBe(true);
  expect(shouldFoldToolRun(row(items, { foldRun: true }), groups, items)).toBe(false);
});
