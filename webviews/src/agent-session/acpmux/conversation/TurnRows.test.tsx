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

const row = (items: AcpmuxActivity[], foldRun = true): AcpmuxRow => ({
  id: "activity",
  version: 1,
  at: 1,
  kind: "activity",
  settled: true,
  foldRun,
  items,
});

test("folds a run the Codex-style runs settled, made only of tool groups", () => {
  const items: AcpmuxActivity[] = [
    command("one", "bun test one"),
    { kind: "tool", text: "Read config", tool: { id: "read", title: "Read", kind: "read", status: "completed" } },
  ];
  expect(toolGroups(items)).toHaveLength(2);
  expect(shouldFoldToolRun(row(items), toolGroups(items), items)).toBe(true);
});

test("keeps each group of an ended turn's run on its own line", () => {
  const items: AcpmuxActivity[] = [
    command("one", "bun test one"),
    { kind: "tool", text: "Read config", tool: { id: "read", title: "Read", kind: "read", status: "completed" } },
  ];
  expect(shouldFoldToolRun(row(items, false), toolGroups(items), items)).toBe(false);
});

test("keeps a coordination message visible beside settled tool calls", () => {
  const items = [message("message"), command("command", "bun test")];
  const groups = toolGroups(items);
  expect(groups.some((group) => group.type === "message")).toBe(true);
  expect(shouldFoldToolRun(row(items), groups, items)).toBe(false);
});
