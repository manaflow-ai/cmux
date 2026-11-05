// l10n-allow-file: test fixture subagent names and text, not shipped UI.
// Leo's Session Info (2026-11-02): rows named "01a18fcd-c1c7-7c…" and "Running" for two hours
// under "15 running · 27 done": "but what's going on with these?". A subagent met first through its
// progress takes its prompt's first line before its id; one whose call is open is never idle; one
// quiet past IDLE_AFTER_MS with no call open is.
import { expect, test } from "bun:test";
import { SubagentFold } from "../src/agent-session/acpmux/subagents/subagentFold";
import { IDLE_AFTER_MS } from "../src/agent-session/acpmux/subagents/idle";
import { subagentStatus } from "../src/agent-session/acpmux/summary/SubagentStatusList";

const update = (update: Record<string, unknown>, acpmux: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update, _meta: { acpmux } },
});
let seq = 0;
const feed = (fold: SubagentFold, at: number, msg: ReturnType<typeof update>) => {
  seq += 1;
  fold.reduce({ seq, at, msg }, msg.params.update);
};
const agent = (fold: SubagentFold, id: string) => fold.all().find((each) => each.id === id)!;
const none = new Set<string>();

test("a subagent met through its progress is named by its prompt before its id", () => {
  const fold = new SubagentFold();
  feed(
    fold,
    1_000,
    update(
      { sessionUpdate: "subagent_progress" },
      { subagents: [{ id: "acp-1/toolu_a", parent: null, state: "running", prompt: "Drop server login\nthen test" }] },
    ),
  );
  expect(agent(fold, "acp-1/toolu_a").name).toBe("Drop server login");
  feed(
    fold,
    2_000,
    update(
      { sessionUpdate: "subagent_progress" },
      { subagents: [{ id: "acp-1/toolu_b", parent: null, state: "running" }] },
    ),
  );
  expect(agent(fold, "acp-1/toolu_b").name).toBe("acp-1/toolu_b");
});

test("a running subagent with an open call stays Running; quiet past the window with none open it is Idle", () => {
  const fold = new SubagentFold();
  const id = "acp-1/toolu_c";
  const sub = { subagent: id };
  feed(
    fold,
    0,
    update(
      { sessionUpdate: "subagent_spawned" },
      { subagents: [{ id, parent: null, name: "Build", state: "running" }] },
    ),
  );
  expect(subagentStatus(agent(fold, id), none, IDLE_AFTER_MS - 1)).toBe("running");
  expect(subagentStatus(agent(fold, id), none, IDLE_AFTER_MS)).toBe("idle");
  // Without the clock nothing is idle (every caller that does not ask).
  expect(subagentStatus(agent(fold, id), none)).toBe("running");
  feed(
    fold,
    1_000,
    update({ sessionUpdate: "tool_call", toolCallId: "t1", title: "make", status: "in_progress" }, sub),
  );
  expect(subagentStatus(agent(fold, id), none, 10 * IDLE_AFTER_MS)).toBe("running");
  feed(fold, 2_000, update({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed" }, sub));
  expect(subagentStatus(agent(fold, id), none, 2_000 + IDLE_AFTER_MS - 1)).toBe("running");
  expect(subagentStatus(agent(fold, id), none, 2_000 + IDLE_AFTER_MS)).toBe("idle");
  // A progress report that repeats its numbers is not work; new tokens are.
  feed(
    fold,
    3_000,
    update({ sessionUpdate: "subagent_progress" }, { subagents: [{ id, parent: null, state: "running", tokens: 5 }] }),
  );
  feed(
    fold,
    9_000,
    update({ sessionUpdate: "subagent_progress" }, { subagents: [{ id, parent: null, state: "running", tokens: 5 }] }),
  );
  expect(agent(fold, id).quietSince).toBe(3_000);
  expect(subagentStatus(agent(fold, id), new Set([id]), 10 * IDLE_AFTER_MS)).toBe("waiting");
});

test("a call opened before the subagent's identity arrives keeps it Running", () => {
  const fold = new SubagentFold();
  const id = "acp-1/toolu_d";
  // A paged log: its open build is read before the progress that names it.
  feed(
    fold,
    0,
    update({ sessionUpdate: "tool_call", toolCallId: "b1", title: "make", status: "in_progress" }, { subagent: id }),
  );
  feed(
    fold,
    1_000,
    update(
      { sessionUpdate: "subagent_progress" },
      { subagents: [{ id, parent: null, name: "Build", state: "running" }] },
    ),
  );
  expect(subagentStatus(agent(fold, id), none, 10 * IDLE_AFTER_MS)).toBe("running");
  feed(
    fold,
    2_000,
    update({ sessionUpdate: "tool_call_update", toolCallId: "b1", status: "completed" }, { subagent: id }),
  );
  expect(subagentStatus(agent(fold, id), none, 2_000 + IDLE_AFTER_MS)).toBe("idle");
});
