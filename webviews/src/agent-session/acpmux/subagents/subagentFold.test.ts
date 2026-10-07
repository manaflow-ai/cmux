import { describe, expect, test } from "bun:test";
import { SUBAGENTS, SubagentFold } from "./subagentFold";

/// A recorded session/update as acpmux sends it, with its `_meta.acpmux` subagent model.
let seq = 0;
const record = (update: Record<string, unknown>, mux?: Record<string, unknown>) => {
  seq += 1;
  return {
    event: {
      seq,
      at: seq * 1000,
      msg: { method: "session/update", params: { sessionId: "s", update, ...(mux && { _meta: { acpmux: mux } }) } },
    },
    update,
  };
};
const spawned = (id: string, name: string, extra: Record<string, unknown> = {}) =>
  record(
    { sessionUpdate: "subagent_spawned", subagentSessionId: id, name, task: name, capabilities: {} },
    { subagents: [{ id, parent: null, name, task: name, state: "running", ...extra }] },
  );
const fold = (fold: SubagentFold, r: ReturnType<typeof record>) => fold.reduce(r.event, r.update);

describe("subagent fold", () => {
  test("subagents spawned together draw as one group row", () => {
    const subagents = new SubagentFold();
    expect(fold(subagents, spawned("a", "Branch A"))).toBe(true);
    expect(fold(subagents, spawned("b", "Branch B"))).toBe(true);
    const rows = subagents.takeRows();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.kind).toBe(SUBAGENTS);
    expect(rows[0]!.subagents!.map((agent) => [agent.name, agent.state])).toEqual([
      ["Branch A", "running"],
      ["Branch B", "running"],
    ]);
    expect(subagents.takeRows()).toEqual([]);
  });

  test("text between spawns starts a new group", () => {
    const subagents = new SubagentFold();
    fold(subagents, spawned("a", "A"));
    subagents.closeBatch();
    fold(subagents, spawned("b", "B"));
    const ids = new Set(subagents.takeRows().map((row) => row.id));
    expect(ids.size).toBe(2);
  });

  test("a subagent's own updates stay out of the transcript and name its current action", () => {
    const subagents = new SubagentFold();
    fold(subagents, spawned("a", "A"));
    const [first] = subagents.takeRows();
    const read = record(
      { sessionUpdate: "tool_call", toolCallId: "t1", title: "Read main.rs", status: "in_progress" },
      { subagent: "a" },
    );
    expect(fold(subagents, read)).toBe(true);
    const text = record(
      { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hi" } },
      { subagent: "a" },
    );
    expect(fold(subagents, text)).toBe(true);
    const [row] = subagents.takeRows();
    expect(row!.id).toBe(first!.id);
    expect(row!.version).toBeGreaterThan(first!.version);
    expect(row!.subagents![0]!.action).toBe("Read main.rs");
  });

  test("a state update ends its subagent", () => {
    const subagents = new SubagentFold();
    fold(subagents, spawned("a", "A"));
    const done = record(
      { sessionUpdate: "subagent_state_update", subagentSessionId: "a", state: "failed" },
      { subagents: [{ id: "a", parent: null, state: "failed" }] },
    );
    expect(fold(subagents, done)).toBe(true);
    const agent = subagents.takeRows()[0]!.subagents![0]!;
    expect(agent.state).toBe("failed");
    expect(agent.endedAt).toBe(done.event.at);
    expect(agent.startedAt).toBeLessThan(agent.endedAt!);
  });

  test("the tool call that started a subagent draws no tool row", () => {
    const subagents = new SubagentFold();
    fold(subagents, spawned("a", "A", { toolCallId: "toolu_1" }));
    const call = record({ sessionUpdate: "tool_call", toolCallId: "toolu_1", title: "A", kind: "think" });
    const result = record({ sessionUpdate: "tool_call_update", toolCallId: "toolu_1", status: "completed" });
    expect(fold(subagents, call)).toBe(true);
    expect(fold(subagents, result)).toBe(true);
    const other = record({ sessionUpdate: "tool_call", toolCallId: "toolu_2", title: "Read" });
    expect(fold(subagents, other)).toBe(false);
  });

  test("a subagent's own subagents stay inside it", () => {
    const subagents = new SubagentFold();
    fold(subagents, spawned("a", "A"));
    const nested = record(
      { sessionUpdate: "subagent_spawned", subagentSessionId: "a1", name: "A1", task: "A1", capabilities: {} },
      { subagent: "a", subagents: [{ id: "a1", parent: "a", name: "A1", state: "running" }] },
    );
    expect(fold(subagents, nested)).toBe(true);
    const rows = subagents.takeRows();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.subagents!.map((agent) => agent.id)).toEqual(["a"]);
    expect(subagents.all().find((agent) => agent.id === "a1")?.parent).toBe("a");
  });

  test("Codex collaboration calls draw as the group of the subagents they spawn", () => {
    const subagents = new SubagentFold();
    const collab = record(
      { sessionUpdate: "tool_call", toolCallId: "call-1", title: "spawnAgent", kind: "other" },
      {
        subagents: [
          { id: "t1", parent: null, task: "split", state: "running", toolCallId: "call-1" },
          { id: "t2", parent: null, task: "split", state: "running", toolCallId: "call-1" },
        ],
      },
    );
    expect(fold(subagents, collab)).toBe(true);
    const agents = subagents.takeRows()[0]!.subagents!;
    expect(agents.map((agent) => agent.id)).toEqual(["t1", "t2"]);
    // A subagent without a name is called by its task.
    expect(agents[0]!.name).toBe("split");
  });

  test("the session's own updates pass through", () => {
    const subagents = new SubagentFold();
    const text = record({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hi" } });
    expect(fold(subagents, text)).toBe(false);
    expect(subagents.takeRows()).toEqual([]);
  });
});
