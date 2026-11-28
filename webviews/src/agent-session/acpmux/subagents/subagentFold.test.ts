import { expect, test } from "bun:test";
import { SUBAGENTS, SubagentFold } from "./subagentFold";

// session/update records as acpmux sends them: a subagent's own updates carry its id in
// `_meta.acpmux.subagent`, spawns and state changes in `_meta.acpmux.subagents`.
let seq = 0;
function feed(fold: SubagentFold, update: any, acpmux: Record<string, unknown> = {}) {
  seq += 1;
  const msg = { method: "session/update", params: { update, _meta: { acpmux } } };
  return fold.reduce({ seq, at: seq * 1000, msg }, update);
}
const say = (text: string) => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });

test("a subagent's own updates draw as its view, with the subagents it spawned as a group", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Audit" }] });
  expect(feed(fold, say("Reading the fetch helper."), { subagent: "a" })).toBe(true);
  feed(
    fold,
    { sessionUpdate: "tool_call", toolCallId: "t1", title: "Read fetch.ts", status: "in_progress" },
    {
      subagent: "a",
    },
  );
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "b", parent: "a", name: "Retries" }] });
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "c", parent: "a", name: "Timeouts" }] });
  feed(fold, say("Retries are fine."), { subagent: "b" });
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "b", state: "completed" }] });
  feed(fold, say("Both checks are in."), { subagent: "a" });

  const views = fold.views();
  const audit = views.a!;
  expect(audit.map((row) => row.kind)).toEqual(["assistant", "activity", SUBAGENTS, "assistant"]);
  expect(audit[0]!.text).toBe("Reading the fetch helper.");
  expect(audit[1]!.items?.[0]?.tool?.title).toBe("Read fetch.ts");
  expect(audit[2]!.subagents?.map((agent) => [agent.name, agent.state])).toEqual([
    ["Retries", "completed"],
    ["Timeouts", "running"],
  ]);
  expect(audit[3]!.text).toBe("Both checks are in.");
  expect(views.b!.map((row) => row.text)).toEqual(["Retries are fine."]);

  // The session's own transcript lists only its own subagent.
  expect(fold.takeRows().flatMap((row) => row.subagents?.map((agent) => agent.id) ?? [])).toEqual(["a"]);
  // A nested subagent's state change redraws its parent's view.
  const before = views.a;
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "c", state: "failed" }] });
  const after = fold.views().a!;
  expect(after).not.toBe(before);
  expect(after[2]!.subagents?.map((agent) => agent.state)).toEqual(["completed", "failed"]);
});
