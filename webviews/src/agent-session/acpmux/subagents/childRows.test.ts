// l10n-allow-file: public-safe child transcript fixtures, not shipped copy.
import { expect, test } from "bun:test";
import { SubagentFold } from "./subagentFold";

type Step = { update: Record<string, unknown>; acpmux: Record<string, unknown> };
const own = (update: Record<string, unknown>, id = "parent"): Step => ({ update, acpmux: { subagent: id } });
const spawn = (id: string, parent: string | null): Step => ({
  update: { sessionUpdate: "subagent_spawned" },
  acpmux: { subagents: [{ id, parent, name: `Sample ${id}` }] },
});
const text = (kind: string, value: string) => own({ sessionUpdate: kind, content: { type: "text", text: value } });
const tool = (id: string, extra: Record<string, unknown> = {}) =>
  own({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: id,
    kind: "execute",
    rawInput: { command: `echo ${id}` },
    ...extra,
  });
const feed = (fold: SubagentFold, step: Step, at: number) =>
  fold.reduce(
    { seq: at, at: at * 1_000, msg: { params: { update: step.update, _meta: { acpmux: step.acpmux } } } },
    step.update,
  );

test("child views preserve call generations, match cold replay and keep old snapshots immutable", () => {
  const steps: Step[] = [
    spawn("parent", null),
    text("agent_message_chunk", "Read the samples."),
    text("agent_thought_chunk", "Inspect "),
    text("agent_thought_chunk", "every item."),
    tool("hidden", { title: "ToolSearch", _meta: { claude: { tool: "ToolSearch" } } }),
    own({ sessionUpdate: "tool_call_update", toolCallId: "hidden", status: "completed" }),
    tool("first", { status: "completed" }),
    tool("second", { status: "in_progress" }),
    text("agent_message_chunk", "First pass finished."),
    spawn("nested", "parent"),
    own({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Nested sample." } }, "nested"),
    own({
      sessionUpdate: "tool_call_update",
      toolCallId: "second",
      status: "completed",
      content: { type: "text", text: "done" },
    }),
    spawn("another", "parent"),
    {
      update: { sessionUpdate: "subagent_state_update" },
      acpmux: { subagents: [{ id: "nested", state: "completed" }] },
    },
    text("agent_message_chunk", "Next pass."),
    text("agent_thought_chunk", "Read another file."),
    tool("read", { kind: "read", locations: [{ path: "sample.ts" }], status: "completed" }),
    text("agent_message_chunk", "Begin another check."),
    own({ sessionUpdate: "tool_call_update", toolCallId: "first", content: { type: "text", text: "late first" } }),
    tool("first", { rawInput: { command: "echo reused" }, status: "in_progress" }),
  ];
  const fold = new SubagentFold();
  let published = fold.views();
  let frozen = JSON.stringify(published);
  for (const [at, step] of steps.entries()) {
    feed(fold, step, at + 1);
    if (at % 4 === 1 || at % 4 === 2) continue;
    const next = fold.views();
    const replay = new SubagentFold();
    steps.slice(0, at + 1).forEach((entry, index) => feed(replay, entry, index + 1));
    expect(next).toEqual(replay.views());
    expect(JSON.stringify(published)).toBe(frozen);
    published = next;
    frozen = JSON.stringify(next);
  }
  const before = fold.views().parent!;
  const activity = before.find((row) => row.kind === "activity")!;
  expect(
    before
      .flatMap((row) => row.items ?? [])
      .filter((item) => item.tool?.id === "first")
      .map((item) => [item.tool?.command, item.tool?.output]),
  ).toEqual([
    ["echo first", "late first"],
    ["echo reused", undefined],
  ]);
  expect(activity.items?.some((item) => item.tool?.id === "hidden")).toBe(false);
  expect(activity.items?.find((item) => item.tool?.id === "second")?.tool?.output).toBe("done");
  feed(
    fold,
    { update: { sessionUpdate: "subagent_state_update" }, acpmux: { subagents: [{ id: "another", state: "failed" }] } },
    steps.length + 1,
  );
  const after = fold.views().parent!;
  expect(after).not.toBe(before);
  expect(after.find((row) => row.id === activity.id)).toBe(activity);
  expect(JSON.stringify(published)).toBe(frozen);
  expect(after.find((row) => row.kind === "subagents")?.subagents?.map((agent) => agent.state)).toEqual([
    "completed",
    "failed",
  ]);
  expect(fold.views().parent).toBe(after);
});
