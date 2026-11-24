// l10n-allow-file: test fixtures.
// A Claude Task or Agent call no subagent record claimed (an adopted chat's replay, adopt_tools.rs)
// reads as its subagent and draws as its card (AgentCallCard.tsx), never as a plain "Agent: …" row.
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { agentCall, splitReport } from "./agentCalls";
import { staysInSight, toolGroups } from "./toolGroups";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const PROMPT = "Find where the transcript parser drops tool results.\n\nReport file paths and line numbers.";
const RESULT = [
  "The parser drops results in `parse.ts:42`.",
  "",
  "- `merge()` skips updates without content",
  "agentId: a39e817af38ddf5e7 (use SendMessage with to: 'a39e817af38ddf5e7' to continue this agent)",
  "<usage>total_tokens: 18234",
  "tool_uses: 14",
  "duration_ms: 72000</usage>",
].join("\n");

const call = (fields: Partial<Tool> = {}): Tool => ({
  id: "toolu_agent",
  title: "Agent: Find the parser",
  kind: "think",
  status: "completed",
  inputSummary: JSON.stringify({ description: "Find the parser", prompt: PROMPT, subagent_type: "Explore" }),
  output: RESULT,
  startedAt: 1_000,
  endedAt: 75_000,
  ...fields,
});

test("a finished Agent call reads as its subagent: kind, words, prompt, report and usage", () => {
  expect(agentCall(call())).toEqual({
    type: "Explore",
    description: "Find the parser",
    prompt: PROMPT,
    report: "The parser drops results in `parse.ts:42`.\n\n- `merge()` skips updates without content",
    running: false,
    failed: false,
    durationMs: 72_000,
    toolUses: 14,
    tokens: 18_234,
  });
});

test("a running call has no report yet; a Task call without a type still reads by its title", () => {
  const running = agentCall(call({ status: "in_progress", output: undefined }));
  expect(running?.running).toBe(true);
  expect(running?.report).toBeUndefined();
  const task = agentCall(
    call({ title: "Task", inputSummary: JSON.stringify({ description: "Check the docs", prompt: "Read docs/" }) }),
  );
  expect(task?.type).toBeUndefined();
  expect(task?.description).toBe("Check the docs");
});

test("other calls are not subagents: no prompt, a shell, an MCP-ish kind, no Agent title or type", () => {
  expect(agentCall(call({ inputSummary: JSON.stringify({ to: "a1", message: "hi" }), title: "SendMessage" }))).toBe(
    undefined,
  );
  expect(
    agentCall(call({ inputSummary: JSON.stringify({ script: "export const meta = {}" }), title: "Workflow" })),
  ).toBe(undefined);
  expect(agentCall(call({ kind: "execute", command: "ls" }))).toBeUndefined();
  expect(agentCall(call({ kind: "read" }))).toBeUndefined();
  expect(agentCall(call({ title: "Ask", inputSummary: JSON.stringify({ prompt: "What now?" }) }))).toBeUndefined();
  expect(agentCall(call({ inputSummary: "not json" }))).toBeUndefined();
});

test("a report line that names an agentId before the trailer stays in the report", () => {
  expect(
    splitReport("agentId: x7 is the stuck one.\nIt never answered.\nagentId: a1\n<usage>tool_uses: 1</usage>").report,
  ).toBe("agentId: x7 is the stuck one.\nIt never answered.");
});

test("the result's trailer is never the report, and a result with only a trailer has none", () => {
  expect(splitReport("agentId: abc\n<usage>tool_uses: 2</usage>")).toEqual({ usage: { toolUses: 2 } });
  expect(splitReport("Done.\nworktreePath: /repo/.claude/worktrees/x\nworktreeBranch: worktree-x").report).toBe(
    "Done.",
  );
});

test("toolGroups draws it as its own card that stays in sight, not as a plain tool item", () => {
  const read: AcpmuxActivity = {
    kind: "tool",
    text: "Read a.ts",
    tool: { id: "read-1", title: "Read a.ts", kind: "read", status: "completed" },
  };
  const agent: AcpmuxActivity = { kind: "tool", text: "Agent: Find the parser", tool: call() };
  const groups = toolGroups([read, agent]);
  expect(groups.map((group) => group.type)).toEqual(["item", "agentCall"]);
  const card = groups[1]!;
  expect(card.type === "agentCall" && card.call.type).toBe("Explore");
  expect(staysInSight(card)).toBe(true);
});
