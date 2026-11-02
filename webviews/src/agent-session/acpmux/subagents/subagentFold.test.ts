import { describe, expect, test } from "bun:test";
import { SUBAGENTS, SubagentFold, stopReasonOf, subagentStops } from "./subagentFold";
import { sessionSummary } from "../summary/sessionSummary";
import { transcriptPullRequestKey, transcriptSummaryVersion } from "../summary/transcriptPullRequests";

// session/update records as acpmux sends them: a subagent's own updates carry its id in
// `_meta.acpmux.subagent`, spawns and state changes in `_meta.acpmux.subagents`.
let seq = 0;
function feed(fold: SubagentFold, update: any, acpmux: Record<string, unknown> = {}) {
  seq += 1;
  const msg = { method: "session/update", params: { update, _meta: { acpmux } } };
  return fold.reduce({ seq, at: seq * 1000, msg }, update);
}
const say = (text: string) => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });

test("a child's tag isolates its work when the loaded page has no spawn record", () => {
  const fold = new SubagentFold();
  fold.chat = "parent";
  expect(feed(fold, say("Parent reply"), { subagent: "parent" })).toBe(false);
  expect(feed(fold, say("Helper reply"), { subagent: "helper" })).toBe(true);
  expect(
    feed(
      fold,
      { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Helper thought" } },
      { subagent: "helper" },
    ),
  ).toBe(true);
  expect(
    feed(
      fold,
      { sessionUpdate: "tool_call", toolCallId: "read", title: "Read helper.ts", status: "in_progress" },
      { subagent: "helper" },
    ),
  ).toBe(true);
  expect(
    feed(fold, { sessionUpdate: "tool_call_update", toolCallId: "read", status: "completed" }, { subagent: "helper" }),
  ).toBe(true);
  expect(fold.all()).toEqual([]);
  expect(fold.takeRows()).toEqual([]);
  const rows = fold.views().helper!;
  expect(rows[0]?.text).toBe("Helper reply");
  expect(rows.flatMap((row) => row.items ?? []).map((item) => item.text)).toContain("Helper thought");
  expect(rows.flatMap((row) => row.items ?? []).find((item) => item.tool?.id === "read")?.tool?.status).toBe(
    "completed",
  );

  feed(
    fold,
    { sessionUpdate: "subagent_progress" },
    { subagents: [{ id: "helper", parent: null, name: "Reviewer", state: "running" }] },
  );
  expect(fold.all().map((agent) => agent.name)).toEqual(["Reviewer"]);
  expect(fold.views().helper![0]?.text).toBe("Helper reply");
  expect(feed(fold, say(" finished"), { subagent: "helper" })).toBe(true);
  expect(feed(fold, say("Parent continues"))).toBe(false);
  expect(fold.views().helper!.at(-1)?.text).toBe(" finished");
});

test("seeded root tags remain parent content even when the current thread differs", () => {
  const fold = new SubagentFold();
  fold.setRoot("earlier-parent-thread");
  fold.chat = "current-parent-thread";
  expect(feed(fold, say("Earlier parent reply"), { subagent: "earlier-parent-thread" })).toBe(false);
  expect(fold.views()).toEqual({});
});

test("a helper missing its spawn still shows a nested dispatch only as the child group", () => {
  const fold = new SubagentFold();
  expect(
    feed(
      fold,
      { sessionUpdate: "tool_call", toolCallId: "spawn", title: "Agent", status: "in_progress" },
      { subagent: "helper", subagents: [{ id: "nested", parent: "helper", name: "Nested", toolCallId: "spawn" }] },
    ),
  ).toBe(true);
  const rows = fold.views().helper!;
  expect(rows.map((row) => row.kind)).toEqual([SUBAGENTS]);
  expect(rows[0]?.subagents?.map((agent) => agent.id)).toEqual(["nested"]);
  expect(fold.takeRows()).toEqual([]);
});

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

test("live child replies stay unsettled and keep the producer revision stable", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Audit" }] });
  feed(fold, say("acme/app#7"), { subagent: "a" });
  const live = fold.views().a!;
  const liveKey = transcriptPullRequestKey(live, true);
  expect(live[0]?.streaming).toBe(true);
  expect(sessionSummary(live, "acme/app").sources).toEqual([]);

  feed(fold, say(" and acme/app#71"), { subagent: "a" });
  const extended = fold.views().a!;
  expect(extended[0]?.streaming).toBe(true);
  expect(transcriptPullRequestKey(extended, true)).toBe(liveKey);
  expect(transcriptSummaryVersion(extended)).toBe(transcriptSummaryVersion(live));
  expect(sessionSummary(extended, "acme/app").sources).toEqual([]);

  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", state: "completed" }] });
  const settled = fold.views().a!;
  expect(settled[0]?.streaming).toBe(false);
  expect(transcriptSummaryVersion(settled)).not.toBe(transcriptSummaryVersion(extended));
  expect(sessionSummary(settled, "acme/app").sources.map((source) => source.label)).toContain("acme/app#7");
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", state: "running" }] });
  feed(fold, say("Next reply"), { subagent: "a" });
  const resumed = fold.views().a!;
  expect(resumed.map((row) => row.streaming)).toEqual([false, true]);
  expect(sessionSummary(resumed, "acme/app").sources.map((source) => source.label)).toContain("acme/app#7");
});

test("late chunks of the same child reply remain joined across completion", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(fold, { ...say("https://github.com/acme/app/pull/4"), messageId: "reply" }, { subagent: "a" });
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", state: "completed" }] });
  feed(fold, { ...say("1"), messageId: "reply" }, { subagent: "a" });
  expect(fold.views().a!.map((row) => row.text)).toEqual(["https://github.com/acme/app/pull/41"]);
  expect(sessionSummary(fold.views().a!, "acme/app").sources.map((source) => source.url)).toEqual([
    "https://github.com/acme/app/pull/41",
  ]);
});

test("resuming a child preserves late completed reply Sources", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", state: "completed" }] });
  feed(fold, { ...say("See https://example.com/late"), messageId: "old" }, { subagent: "a" });
  expect(sessionSummary(fold.views().a!, "acme/app").sources.map((source) => source.url)).toContain(
    "https://example.com/late",
  );
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", state: "running" }] });
  expect(sessionSummary(fold.views().a!, "acme/app").sources.map((source) => source.url)).toContain(
    "https://example.com/late",
  );
  feed(fold, { ...say("New reply"), messageId: "new" }, { subagent: "a" });
  expect(fold.views().a!.map((row) => row.streaming)).toEqual([false, true]);
  expect(sessionSummary(fold.views().a!, "acme/app").sources.map((source) => source.url)).toContain(
    "https://example.com/late",
  );
});

test("post-completion child reply chunks invalidate the summary revision", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", state: "completed" }] });
  const sayWithId = (text: string) =>
    feed(fold, { ...say(text), messageId: "post-completion-reply" }, { subagent: "a" });
  sayWithId("See https://example.com/first");
  const first = sessionSummary(fold.views().a!);
  sayWithId(" and https://example.com/second");
  const second = sessionSummary(fold.views().a!);
  expect(second).not.toBe(first);
  expect(second.sources.map((source) => source.url)).toEqual([
    "https://example.com/first",
    "https://example.com/second",
  ]);
});

test("the first nonempty child thought settles reply Sources without rescanning later chunks", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(
    fold,
    say("See https://example.com/guide, acme/app#7, and https://github.com/acme/app/issues/7#issuecomment-123"),
    {
      subagent: "a",
    },
  );
  const live = sessionSummary(fold.views().a!, "acme/app");
  expect(live.sources).toEqual([]);
  const think = (text: string) =>
    feed(fold, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text } }, { subagent: "a" });
  think("");
  expect(sessionSummary(fold.views().a!, "acme/app")).toBe(live);
  think("Checking the next step");
  const settled = sessionSummary(fold.views().a!, "acme/app");
  expect(settled.sources.map((source) => source.url)).toEqual([
    "https://example.com/guide",
    "https://github.com/acme/app/issues/7",
  ]);
  for (let index = 0; index < 50; index++) {
    think(" more");
    expect(sessionSummary(fold.views().a!, "acme/app")).toBe(settled);
  }
});

test("hidden ToolSearch does not settle a child reply before a rendered thought", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(fold, say("See https://example.com/guide"), { subagent: "a" });
  const live = sessionSummary(fold.views().a!, "acme/app");
  expect(live.sources).toEqual([]);
  feed(
    fold,
    {
      sessionUpdate: "tool_call",
      toolCallId: "search",
      title: "ToolSearch",
      status: "completed",
      _meta: { claude: { tool: "ToolSearch" } },
    },
    { subagent: "a" },
  );
  feed(fold, { sessionUpdate: "tool_call_update", toolCallId: "search", status: "completed" }, { subagent: "a" });
  feed(fold, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Checking" } }, { subagent: "a" });
  expect(sessionSummary(fold.views().a!, "acme/app").sources.map((source) => source.url)).toEqual([
    "https://example.com/guide",
  ]);
});

test("an unknown hidden tool result does not settle a child reply", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(fold, say("See https://example.com/guide"), { subagent: "a" });
  feed(fold, { sessionUpdate: "tool_call_update", toolCallId: "search", status: "completed" }, { subagent: "a" });
  feed(fold, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Checking" } }, { subagent: "a" });
  expect(sessionSummary(fold.views().a!, "acme/app").sources.map((source) => source.url)).toEqual([
    "https://example.com/guide",
  ]);
});

test("a known titleless tool completion settles a child reply", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(fold, say("See https://example.com/guide"), { subagent: "a" });
  const live = sessionSummary(fold.views().a!, "acme/app");
  expect(live.sources).toEqual([]);
  feed(
    fold,
    { sessionUpdate: "tool_call", toolCallId: "read", title: "Read guide", status: "in_progress" },
    { subagent: "a" },
  );
  feed(fold, { sessionUpdate: "tool_call_update", toolCallId: "read", status: "completed" }, { subagent: "a" });
  expect(sessionSummary(fold.views().a!, "acme/app").sources.map((source) => source.url)).toEqual([
    "https://example.com/guide",
  ]);
});

test("a child messageId change settles the prior reply Sources", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(fold, { ...say("See https://github.com/acme/app/pull/41"), messageId: "msg-1" }, { subagent: "a" });
  feed(fold, { ...say("Continue here"), messageId: "msg-2" }, { subagent: "a" });
  const rows = fold.views().a!;
  expect(rows.filter((row) => row.kind === "assistant")).toMatchObject([
    { text: "See https://github.com/acme/app/pull/41", streaming: false },
    { text: "Continue here", streaming: true },
  ]);
  expect(sessionSummary(rows, "acme/app").sources).toMatchObject([
    { url: "https://github.com/acme/app/pull/41", kind: "pullRequest" },
  ]);
});

test("the first child tool after a reply settles its Sources", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(fold, say("Read https://example.com/guide"), { subagent: "a" });
  const live = sessionSummary(fold.views().a!, "acme/app");
  expect(live.sources).toEqual([]);
  feed(
    fold,
    { sessionUpdate: "tool_call", toolCallId: "t1", title: "Read guide", status: "in_progress" },
    { subagent: "a" },
  );
  expect(sessionSummary(fold.views().a!, "acme/app").sources.map((source) => source.url)).toEqual([
    "https://example.com/guide",
  ]);
});

test("a running tool update keeps a settled child reply in Sources", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(
    fold,
    { sessionUpdate: "tool_call", toolCallId: "t1", title: "Read guide", status: "in_progress" },
    { subagent: "a" },
  );
  feed(fold, say("Read https://example.com/guide"), { subagent: "a" });
  const settled = sessionSummary(fold.views().a!, "acme/app");
  feed(
    fold,
    { sessionUpdate: "tool_call_update", toolCallId: "t1", title: "Read guide", status: "in_progress" },
    { subagent: "a" },
  );
  const afterUpdate = sessionSummary(fold.views().a!, "acme/app");
  expect(afterUpdate.sources).toEqual([{ url: "https://example.com/guide", label: "example.com/guide", kind: "url" }]);
  expect(afterUpdate).not.toBe(settled);
});

test("nested renaming and completion invalidate the parent summary revision", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Parent" }] });
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "b", parent: "a", name: "Child" }] });
  const before = sessionSummary(fold.views().a!, "acme/app");
  expect(before.subagents).toEqual([{ id: "b", title: "Child", state: "running" }]);
  feed(
    fold,
    { sessionUpdate: "subagent_state_update" },
    { subagents: [{ id: "b", name: "Renamed", state: "running" }] },
  );
  expect(sessionSummary(fold.views().a!, "acme/app").subagents).toEqual([
    { id: "b", title: "Renamed", state: "running" },
  ]);

  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "b", state: "completed" }] });
  const after = sessionSummary(fold.views().a!, "acme/app");
  expect(after).not.toBe(before);
  expect(after.subagents).toEqual([{ id: "b", title: "Renamed", state: "done" }]);
});

test("running nested tool metadata invalidates the child summary", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "parent", parent: null }] });
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: "parent" }] });
  const child = (update: object) => feed(fold, update, { subagent: "child" });
  child({ sessionUpdate: "tool_call", toolCallId: "live", title: "Before", kind: "think", status: "in_progress" });
  expect(sessionSummary(fold.views().child!).subagents).toEqual([{ id: "live", title: "Before", state: "running" }]);
  child({ sessionUpdate: "tool_call_update", toolCallId: "live", name: "After", status: "in_progress" });
  expect(sessionSummary(fold.views().child!).subagents).toEqual([{ id: "live", title: "After", state: "running" }]);
  child({
    sessionUpdate: "tool_call_update",
    toolCallId: "live",
    kind: "execute",
    title: "npm run dev",
    rawInput: { command: "npm run dev", description: "Preview", run_in_background: true },
  });
  expect(sessionSummary(fold.views().child!).backgroundTasks).toMatchObject([
    { command: "npm run dev", description: "Preview", state: "running" },
  ]);
});

test("mixed child activity and nested streams reuse summaries until completion", () => {
  const fold = new SubagentFold();
  const childUpdate = (update: object) => feed(fold, update, { subagent: "b" });
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "b", parent: "a" }] });
  childUpdate({
    sessionUpdate: "tool_call",
    toolCallId: "done",
    title: "Read",
    kind: "read",
    status: "completed",
    locations: [{ path: "before.ts" }],
  });
  expect(sessionSummary(fold.views().b!).sources.map((source) => source.label)).toEqual(["before.ts"]);
  childUpdate({ sessionUpdate: "tool_call_update", toolCallId: "done", locations: [{ path: "after.ts" }] });
  expect(sessionSummary(fold.views().b!).sources.map((source) => source.label)).toEqual(["after.ts"]);
  childUpdate({ sessionUpdate: "tool_call", toolCallId: "live", title: "Work", kind: "think", status: "in_progress" });
  expect(sessionSummary(fold.views().b!).subagents).toEqual([{ id: "live", title: "Work", state: "running" }]);
  const parent = sessionSummary(fold.views().a!, "acme/app");
  for (let index = 0; index < 50; index++) {
    childUpdate({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "thinking" } });
    childUpdate({ sessionUpdate: "tool_call_update", toolCallId: "live", title: "Work", status: "in_progress" });
    expect(sessionSummary(fold.views().a!, "acme/app")).toBe(parent);
  }
  const child = sessionSummary(fold.views().b!, "acme/app");
  childUpdate({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "more" } });
  expect(sessionSummary(fold.views().b!, "acme/app")).toBe(child);
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "b", state: "completed" }] });
  expect(sessionSummary(fold.views().a!, "acme/app").subagents[0]?.state).toBe("done");
});

describe("why a subagent stopped", () => {
  const spawn = (fold: SubagentFold, id: string, fields: Record<string, unknown> = {}) =>
    feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id, parent: null, name: id, ...fields }] });
  const end = (fold: SubagentFold, id: string, state: string) =>
    feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id, state }] });
  const reasons = (fold: SubagentFold) => fold.all().map((agent) => [agent.id, agent.state, agent.stopReason]);

  test("a stop while Send now or the pane's Stop ends the turn is theirs; else no reason", () => {
    const fold = new SubagentFold();
    spawn(fold, "a");
    spawn(fold, "b");
    spawn(fold, "c");
    fold.cause = "sendNow";
    end(fold, "a", "cancelled");
    fold.cause = "user";
    end(fold, "b", "cancelled");
    fold.cause = undefined;
    end(fold, "c", "cancelled");
    expect(reasons(fold)).toEqual([
      ["a", "cancelled", "sendNow"],
      ["b", "cancelled", "user"],
      ["c", "cancelled", undefined],
    ]);
  });

  test("finished and failed ones carry no stop reason, even while a stop ends the turn", () => {
    const fold = new SubagentFold();
    spawn(fold, "a");
    spawn(fold, "b");
    fold.cause = "user";
    end(fold, "a", "completed");
    end(fold, "b", "failed");
    expect(reasons(fold)).toEqual([
      ["a", "completed", undefined],
      ["b", "failed", undefined],
    ]);
  });

  test("a background subagent outlives its turn's stop: the turn's cause is not its reason", () => {
    const fold = new SubagentFold();
    spawn(fold, "bg", { background: true });
    fold.cause = "sendNow";
    end(fold, "bg", "cancelled");
    expect(reasons(fold)).toEqual([["bg", "cancelled", undefined]]);
  });

  test("one the pane asked to stop was stopped by the person, background or not", () => {
    const stops = subagentStops();
    const fold = new SubagentFold(stops);
    spawn(fold, "bg", { background: true });
    stops.requested.add("bg");
    end(fold, "bg", "cancelled");
    expect(reasons(fold)).toEqual([["bg", "cancelled", "user"]]);
    expect(stops.requested.size).toBe(0);
  });

  test("the turn's stop ending the rest of its subagents gives them its cause", () => {
    const fold = new SubagentFold();
    fold.startTurn();
    spawn(fold, "a");
    fold.cause = "sendNow";
    expect(fold.stopRunning({ state: "cancelled", turn: true }, 9_000)).toBe(true);
    expect(reasons(fold)).toEqual([["a", "cancelled", "sendNow"]]);
  });

  test("a reason outlives a rebuild of the fold; one that runs again forgets it", () => {
    const stops = subagentStops();
    const first = new SubagentFold(stops);
    spawn(first, "a");
    first.cause = "user";
    end(first, "a", "cancelled");
    // The rebuild replays the records without the pane's Stop.
    const again = new SubagentFold(stops);
    spawn(again, "a");
    end(again, "a", "cancelled");
    expect(reasons(again)).toEqual([["a", "cancelled", "user"]]);
    end(again, "a", "running");
    expect(reasons(again)).toEqual([["a", "running", undefined]]);
  });

  test("a subagent an earlier turn started takes no reason from this turn's stop", () => {
    const fold = new SubagentFold();
    fold.startTurn();
    spawn(fold, "old");
    fold.startTurn();
    spawn(fold, "new");
    fold.cause = "sendNow";
    end(fold, "old", "cancelled");
    end(fold, "new", "cancelled");
    expect(reasons(fold)).toEqual([
      ["old", "cancelled", undefined],
      ["new", "cancelled", "sendNow"],
    ]);
  });

  test("one that runs again forgets its old reason: a later stop with no known cause has none", () => {
    const stops = subagentStops();
    const fold = new SubagentFold(stops);
    spawn(fold, "a");
    fold.cause = "user";
    end(fold, "a", "cancelled");
    fold.cause = undefined;
    end(fold, "a", "running");
    end(fold, "a", "cancelled");
    expect(reasons(fold)).toEqual([["a", "cancelled", undefined]]);
    expect(stops.reasons.has("a")).toBe(false);
  });

  test("the prompt it was given is kept for Restart", () => {
    const fold = new SubagentFold();
    spawn(fold, "a", { prompt: "Review src/app.ts", kind: "Explore" });
    expect(fold.all()[0]).toMatchObject({ prompt: "Review src/app.ts", kind: "Explore" });
  });
});

describe("stopReasonOf", () => {
  test("only a stopped (cancelled) subagent has a reason, and an unknown one has none", () => {
    const stops = subagentStops();
    expect(stopReasonOf({ id: "a", state: "disconnected" }, stops, "user")).toBeUndefined();
    expect(stopReasonOf({ id: "a", state: "cancelled" }, stops, undefined)).toBeUndefined();
    expect(stopReasonOf({ id: "a", state: "cancelled" }, stops, "sendNow")).toBe("sendNow");
  });
});

test("a Claude Agent call's result gives its subagent the agentId a SendMessage to it names", async () => {
  const { agentNames } = await import("../conversation/agentNames");
  const fold = new SubagentFold();
  feed(
    fold,
    { sessionUpdate: "subagent_spawned" },
    { subagents: [{ id: "s/t9", parent: null, name: "Fix grid jump", task: "Fix grid jump", toolCallId: "t9" }] },
  );
  fold.takeRows();
  // The call's result is swallowed with the call; its agentId lands on the subagent.
  const result = {
    sessionUpdate: "tool_call_update",
    toolCallId: "t9",
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "text",
          text: "Async agent launched successfully.\nagentId: a39e817af38ddf5e7 (internal ID - do not mention to user.)",
        },
      },
    ],
  };
  expect(feed(fold, result)).toBe(true);
  const agents = fold.takeRows().flatMap((row) => row.subagents ?? []);
  expect(agents.map((agent) => agent.agentId)).toEqual(["a39e817af38ddf5e7"]);
  expect(agentNames(agents).get("a39e817af38ddf5e7")).toBe("Fix grid jump");
});

test("the agentId is the last one a result names, after a report that mentions another", async () => {
  const { agentIdIn } = await import("./subagentFold");
  expect(agentIdIn("Found agentId: aaaa1111bbbb2222 in the log.\n\nagentId: a39e817af38ddf5e7 (internal ID)")).toBe(
    "a39e817af38ddf5e7",
  );
  expect(agentIdIn("no id here")).toBeUndefined();
});

// Leo's Codex chat, 2026-10-22 ("why is it like... staggered? were they created by another
// subagent?"): its records as acpmux wrote them. The child `needs_you_review` reported the chat's
// own thread as running under its own session, acpmux recorded the chat as that child's subagent,
// and from then on tagged the chat's own updates and spawns with the chat's id. The tray drew
// needs_you_review › 01a1658b-… › needs_you_prior_art.
describe("lineage from a Codex chat's records", () => {
  const chat = "01a1658b-c32f-72b1-ab04-d5444235a91c";
  const review = "01a16655-c696-7982-9c38-9ededd986f9b";
  const priorArt = "01a16656-bb2d-7513-b459-4a893451d37a";
  const at = (fold: SubagentFold, sessionId: string, update: any, acpmux: Record<string, unknown> = {}) => {
    seq += 1;
    const msg = { method: "session/update", params: { sessionId, update, _meta: { acpmux } } };
    return fold.reduce({ seq, at: seq * 1000, msg }, update);
  };
  const records = (fold: SubagentFold) => {
    at(fold, chat, say("Starting the reviews."));
    at(
      fold,
      chat,
      { sessionUpdate: "subagent_spawned", subagentSessionId: review, name: "needs_you_review" },
      {
        subagents: [{ id: review, parent: null, name: "needs_you_review", task: "needs_you_review", state: "running" }],
      },
    );
    at(
      fold,
      review,
      { sessionUpdate: "subagent_state_update", subagentSessionId: chat, state: "running" },
      { subagent: review, subagents: [{ id: chat, parent: review, state: "running" }] },
    );
    at(
      fold,
      chat,
      { sessionUpdate: "subagent_spawned", subagentSessionId: priorArt, name: "needs_you_prior_art" },
      {
        subagent: chat,
        subagents: [{ id: priorArt, parent: chat, name: "needs_you_prior_art", task: "needs_you_prior_art" }],
      },
    );
    return at(fold, chat, say("Both are running."), { subagent: chat });
  };
  const lineage = (fold: SubagentFold) => fold.all().map((agent) => [agent.name, agent.parent]);

  test("the chat is never its own subagent, and its children sit side by side", () => {
    const fold = new SubagentFold();
    fold.chat = chat;
    const own = records(fold);
    expect(lineage(fold)).toEqual([
      ["needs_you_review", null],
      ["needs_you_prior_art", null],
    ]);
    // The chat's own words draw in its transcript, not in a subagent's view.
    expect(own).toBe(false);
    expect(fold.takeRows().flatMap((row) => row.subagents?.map((agent) => agent.name) ?? [])).toEqual([
      "needs_you_review",
      "needs_you_prior_art",
    ]);
  });

  test("without the chat's thread the fold names it, so the pane knows to fold again", () => {
    const fold = new SubagentFold();
    records(fold);
    expect(fold.names(chat)).toBe(true);
    // A page that starts after the record that made the chat a subagent names it only as a parent
    // and an owner.
    const later = new SubagentFold();
    at(
      later,
      chat,
      { sessionUpdate: "subagent_spawned", subagentSessionId: priorArt, name: "needs_you_prior_art" },
      { subagent: chat, subagents: [{ id: priorArt, parent: chat, name: "needs_you_prior_art" }] },
    );
    expect(later.names(chat)).toBe(true);
    expect(later.names("01a1658b-0000-7000-8000-000000000000")).toBe(false);
  });

  test("a page that starts after the bad record reads the chat from the summary", () => {
    const fold = new SubagentFold();
    fold.chat = chat;
    at(
      fold,
      chat,
      { sessionUpdate: "subagent_spawned", subagentSessionId: priorArt, name: "needs_you_prior_art" },
      { subagent: chat, subagents: [{ id: priorArt, parent: chat, name: "needs_you_prior_art" }] },
    );
    expect(at(fold, chat, say("Still on it."), { subagent: chat })).toBe(false);
    expect(lineage(fold)).toEqual([["needs_you_prior_art", null]]);
  });

  test("native subagent progress keeps optional model, effort and lastMessage fields", () => {
    const fold = new SubagentFold();
    const update = { sessionUpdate: "subagent_progress" };
    const meta = {
      subagents: [
        {
          id: "native-worker",
          parent: null,
          state: "running",
          model: "gpt-6-astra",
          effort: "high",
          lastMessage: "Reviewing the changed files.",
          tokens: 321,
        },
      ],
    };
    fold.reduce({ seq: 1, at: 1000, msg: { params: { update, _meta: { acpmux: meta } } } }, update);
    expect(fold.all().find((agent) => agent.id === "native-worker")).toMatchObject({
      model: "gpt-6-astra",
      effort: "high",
      lastMessage: "Reviewing the changed files.",
      tokens: 321,
    });
    fold.reduce(
      {
        seq: 2,
        at: 2000,
        msg: {
          params: {
            update,
            _meta: { acpmux: { subagents: [{ id: "native-worker", model: null, effort: null, lastMessage: null }] } },
          },
        },
      },
      update,
    );
    const cleared = fold.all().find((agent) => agent.id === "native-worker")!;
    expect(cleared).not.toHaveProperty("model");
    expect(cleared).not.toHaveProperty("effort");
    expect(cleared).not.toHaveProperty("lastMessage");
  });
});

test("replay keeps an echoed native root out of direct collaboration siblings", () => {
  const fold = new SubagentFold();
  // The session summary seeds this in production; the optional call keeps this fixture red on
  // the pre-fix fold, where replay has no native-root identity at all.
  (fold as any).setRoot?.("root-native");
  const replay = (update: any, acpmux: Record<string, unknown>, senderThreadId: string) => {
    seq += 1;
    const withCodex = { ...update, _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } } };
    const msg = {
      method: "session/update",
      params: {
        update: withCodex,
        _meta: { acpmux },
      },
    };
    return fold.reduce({ seq, at: seq * 1000, msg }, withCodex);
  };

  // Persisted acpmux output had already attached both direct children to the native root. The
  // root itself was also echoed as if review had spawned it, which is the phantom middle row.
  replay(
    { sessionUpdate: "subagent_spawned" },
    { subagents: [{ id: "review", parent: "root-native" }] },
    "root-native",
  );
  replay(
    { sessionUpdate: "subagent_spawned" },
    { subagent: "review", subagents: [{ id: "root-native", parent: "review" }] },
    "root-native",
  );
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "prior", parent: "root-native" }] }, "root-native");

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
    ["review", null],
    ["prior", null],
  ]);
});

test("sender identity keeps a real grandchild under its child", () => {
  const fold = new SubagentFold();
  const replay = (update: any, acpmux: Record<string, unknown>, senderThreadId: string) => {
    seq += 1;
    const withCodex = { ...update, _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } } };
    const msg = {
      method: "session/update",
      params: {
        update: withCodex,
        _meta: { acpmux },
      },
    };
    return fold.reduce({ seq, at: seq * 1000, msg }, withCodex);
  };
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "root-child", parent: null }] }, "root-native");
  replay(
    { sessionUpdate: "subagent_spawned" },
    { subagent: "root-child", subagents: [{ id: "grandchild", parent: null }] },
    "root-child",
  );

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
    ["root-child", null],
    ["grandchild", "root-child"],
  ]);
});

test("an unknown sender keeps the persisted parent during replay", () => {
  const fold = new SubagentFold();
  const replay = (update: any, acpmux: Record<string, unknown>, senderThreadId: string) => {
    seq += 1;
    const withCodex = { ...update, _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } } };
    const msg = {
      method: "session/update",
      params: {
        update: withCodex,
        _meta: { acpmux },
      },
    };
    return fold.reduce({ seq, at: seq * 1000, msg }, withCodex);
  };
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "known", parent: null }] }, "root-native");
  replay(
    { sessionUpdate: "subagent_spawned" },
    { subagent: "known", subagents: [{ id: "unseen", parent: "known" }] },
    "missing-sender",
  );

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
    ["known", null],
    ["unseen", "known"],
  ]);
});

test("a resolved sender replaces a stale persisted parent", () => {
  const fold = new SubagentFold();
  const replay = (update: any, acpmux: Record<string, unknown>, senderThreadId: string) => {
    seq += 1;
    const withCodex = { ...update, _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } } };
    const msg = { method: "session/update", params: { update: withCodex, _meta: { acpmux } } };
    return fold.reduce({ seq, at: seq * 1000, msg }, withCodex);
  };
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "known", parent: null }] }, "root-native");
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "unseen", parent: "known" }] }, "missing-sender");
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "missing-sender", parent: null }] }, "root-native");

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
    ["known", null],
    ["unseen", "missing-sender"],
    ["missing-sender", null],
  ]);
  expect(
    fold
      .views()
      .known?.flatMap((row) => row.subagents ?? [])
      .map(({ id }) => id),
  ).toEqual([]);
  expect(
    fold
      .views()
      ["missing-sender"]?.flatMap((row) => row.subagents ?? [])
      .map(({ id }) => id),
  ).toEqual(["unseen"]);
});

test("authoritative lineage clears a stale pending sender", () => {
  const fold = new SubagentFold();
  fold.setRoot("root-native");
  const replay = (update: any, acpmux: Record<string, unknown>, senderThreadId: string) => {
    seq += 1;
    const withCodex = { ...update, _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } } };
    const msg = { method: "session/update", params: { update: withCodex, _meta: { acpmux } } };
    return fold.reduce({ seq, at: seq * 1000, msg }, withCodex);
  };
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "parent", parent: null }] }, "root-native");
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: "parent" }] }, "unseen-sender");
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: null }] }, "root-native");
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "unseen-sender", parent: null }] }, "root-native");

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
    ["parent", null],
    ["child", null],
    ["unseen-sender", null],
  ]);
});

test("replay reparents a grandchild when its sender spawn arrives later", () => {
  const fold = new SubagentFold();
  fold.setRoot("root-native");
  const replay = (update: any, acpmux: Record<string, unknown>, senderThreadId: string) => {
    seq += 1;
    const withCodex = { ...update, _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } } };
    const msg = { method: "session/update", params: { update: withCodex, _meta: { acpmux } } };
    return fold.reduce({ seq, at: seq * 1000, msg }, withCodex);
  };
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "grandchild", parent: null }] }, "child");
  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([["grandchild", null]]);
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: null }] }, "root-native");

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
    ["grandchild", "child"],
    ["child", null],
  ]);
});

test("a known child sender in a root-wrapped update remains the grandchild parent", () => {
  const fold = new SubagentFold();
  const replay = (senderThreadId: string, acpmux: Record<string, unknown>) => {
    seq += 1;
    const update = {
      sessionUpdate: "subagent_spawned",
      _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } },
    };
    const msg = { method: "session/update", params: { update, _meta: { acpmux } } };
    return fold.reduce({ seq, at: seq * 1000, msg }, update);
  };
  replay("root-native", { subagents: [{ id: "child", parent: null }] });
  // The wrapper can report this child call on the root session, so there is no mux.subagent.
  replay("child", { subagents: [{ id: "grandchild", parent: null }] });

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
    ["child", null],
    ["grandchild", "child"],
  ]);
});

test("an authoritative root sender reparents an existing child to the top level", () => {
  const fold = new SubagentFold();
  fold.setRoot("root-native");
  const replay = (acpmux: Record<string, unknown>, senderThreadId: string) => {
    seq += 1;
    const update = {
      sessionUpdate: "subagent_spawned",
      _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } },
    };
    const msg = { method: "session/update", params: { update, _meta: { acpmux } } };
    return fold.reduce({ seq, at: seq * 1000, msg }, update);
  };
  replay({ subagents: [{ id: "parent", parent: null }] }, "root-native");
  replay({ subagents: [{ id: "child", parent: "parent" }] }, "parent");
  const startedAt = fold.all().find(({ id }) => id === "child")!.startedAt;
  fold.takeRows();
  fold.closeBatch();
  replay({ subagents: [{ id: "later", parent: null }] }, "root-native");
  replay({ subagents: [{ id: "child", parent: null }] }, "root-native");

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
    ["parent", null],
    ["child", null],
    ["later", null],
  ]);
  expect(
    fold
      .views()
      .parent?.flatMap((row) => row.subagents ?? [])
      .map(({ id }) => id),
  ).toEqual([]);
  const rows = fold.takeRows();
  expect(rows.find((row) => row.subagents?.some(({ id }) => id === "child"))?.at).toBe(startedAt);
  expect(rows.find((row) => row.subagents?.some(({ id }) => id === "later"))?.subagents?.map(({ id }) => id)).toEqual([
    "later",
  ]);
});

test("an authoritative child sender moves an existing worker and refuses an ancestor cycle", () => {
  const fold = new SubagentFold();
  fold.setRoot("root-native");
  feed(
    fold,
    { sessionUpdate: "subagent_spawned" },
    {
      subagents: [
        { id: "a", parent: null },
        { id: "b", parent: "a" },
        { id: "c", parent: null },
      ],
    },
  );
  const update = {
    sessionUpdate: "subagent_spawned",
    _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId: "c" } } },
  };
  feed(fold, update, { subagents: [{ id: "b", parent: "a" }] });
  expect(fold.all().find(({ id }) => id === "b")?.parent).toBe("c");
  expect(
    fold
      .views()
      .a?.flatMap((row) => row.subagents ?? [])
      .map(({ id }) => id),
  ).toEqual([]);
  expect(
    fold
      .views()
      .c?.flatMap((row) => row.subagents ?? [])
      .map(({ id }) => id),
  ).toEqual(["b"]);
  feed(fold, update, { subagents: [{ id: "c", parent: null }] });
  const cycle = {
    ...update,
    _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId: "b" } } },
  };
  feed(fold, cycle, { subagents: [{ id: "c", parent: "b" }] });
  expect(fold.all().find(({ id }) => id === "c")?.parent).toBeNull();
  expect(fold.all().find(({ id }) => id === "b")?.parent).toBe("c");
});

for (const move of ["pending-agent", "pending-root", "known-agent", "known-root", "phantom"] as const) {
  test(`removing a spawn rebuilds its rendered parent view: ${move}`, () => {
    const fold = new SubagentFold();
    fold.setRoot("root-native");
    feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null }] });
    if (move === "known-agent")
      feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "c", parent: null }] });
    feed(fold, say("Before."), { subagent: "a" });
    const update = {
      sessionUpdate: "subagent_spawned",
      _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId: "c" } } },
    };
    const pending = move === "pending-agent" || move === "pending-root";
    feed(fold, pending ? update : { sessionUpdate: "subagent_spawned" }, {
      subagents: [{ id: "b", parent: "a" }],
    });
    feed(fold, say("After."), { subagent: "a" });
    expect(
      fold
        .views()
        .a?.flatMap((row) => row.subagents ?? [])
        .map(({ id }) => id),
    ).toEqual(["b"]);

    if (move === "pending-agent")
      feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "c", parent: null }] });
    else if (move === "pending-root") fold.setRoot("c");
    else if (move === "phantom") fold.setRoot("b");
    else {
      const senderThreadId = move === "known-agent" ? "c" : "root-native";
      feed(
        fold,
        {
          ...update,
          _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } },
        },
        { subagents: [{ id: "b", parent: null }] },
      );
    }

    const views = fold.views();
    expect(views.a?.flatMap((row) => row.subagents ?? []).map(({ id }) => id)).toEqual([]);
    expect(
      views.a
        ?.filter((row) => row.kind === "assistant")
        .map((row) => row.text)
        .join(""),
    ).toBe("Before.After.");
    if (move === "pending-agent" || move === "known-agent")
      expect(views.c?.flatMap((row) => row.subagents ?? []).map(({ id }) => id)).toEqual(["b"]);
    else if (move === "phantom") expect(fold.all().some(({ id }) => id === "b")).toBe(false);
    else
      expect(
        fold
          .takeRows()
          .flatMap((row) => row.subagents ?? [])
          .filter(({ id }) => id === "b"),
      ).toHaveLength(1);
    feed(fold, say("More."), { subagent: "a" });
    expect(
      fold
        .views()
        .a?.filter((row) => row.kind === "assistant")
        .map((row) => row.text)
        .join(""),
    ).toBe("Before.After.More.");
  });
}

test("late root seeding removes a phantom and promotes its children", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "root-native", parent: "child" }] });
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: "root-native" }] });
  fold.setRoot("root-native");

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([["child", null]]);
});

test("late root seeding removes phantom groups from existing child views", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "root-native", parent: null }] });
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: "root-native" }] });
  // The root's group and the child's view were both materialized before the summary supplied the
  // native identity. A cleanup must remove the old group marker, not merely hide its agent object.
  fold.takeRows();
  fold.setRoot("root-native");

  expect(fold.views().root).toBeUndefined();
  expect(fold.views().child).toBeUndefined();
  expect(
    fold
      .takeRows()
      .flatMap((row) => row.subagents ?? [])
      .map(({ id, parent }) => [id, parent]),
  ).toEqual([["child", null]]);

  const childView = new SubagentFold();
  feed(childView, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "root-native", parent: "child" }] });
  feed(childView, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: "root-native" }] });
  childView.setRoot("root-native");
  expect(childView.views().child).toEqual([]);
});

test("a known root repairs a historical child parent before drawing it", () => {
  const fold = new SubagentFold();
  fold.setRoot("root-native");
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "review", parent: "root-native" }] });
  const update = {
    sessionUpdate: "subagent_spawned",
    _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId: "root-native" } } },
  };
  seq += 1;
  fold.reduce(
    {
      seq,
      at: seq * 1000,
      msg: {
        method: "session/update",
        params: { update, _meta: { acpmux: { subagents: [{ id: "review", parent: "root-native" }] } } },
      },
    },
    update,
  );

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([["review", null]]);
  expect(fold.views().review).toBeUndefined();
  expect(
    fold
      .takeRows()
      .flatMap((row) => row.subagents ?? [])
      .map(({ id, parent }) => [id, parent]),
  ).toEqual([["review", null]]);
});

test("a stale root parent on a known child's progress does not promote its grandchild", () => {
  const fold = new SubagentFold();
  fold.setRoot("root-native");
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: null }] });
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "grandchild", parent: "child" }] });
  const update = {
    sessionUpdate: "subagent_progress",
    _meta: { codex: { collaboration: { tool: "wait", senderThreadId: "child" } } },
  };
  seq += 1;
  fold.reduce(
    {
      seq,
      at: seq * 1000,
      msg: {
        method: "session/update",
        params: {
          update,
          _meta: { acpmux: { subagents: [{ id: "grandchild", parent: "root-native", action: "Checking" }] } },
        },
      },
    },
    update,
  );
  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
    ["child", null],
    ["grandchild", "child"],
  ]);
});

test("late root seeding promotes children of a root that never had its own row", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: "root-native" }] });
  fold.setRoot("root-native");

  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([["child", null]]);
});

test("late root seeding keeps a promoted child where it started, out of a later batch", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "root-native", parent: null }] });
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: "root-native" }] });
  const childAt = seq * 1000;
  fold.closeBatch();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "later", parent: null }] });
  fold.takeRows();
  fold.setRoot("root-native");

  const rows = fold.takeRows();
  const withChild = rows.find((row) => row.subagents?.some(({ id }) => id === "child"));
  expect(withChild?.at).toBe(childAt);
  expect(withChild?.subagents?.map(({ id }) => id)).toEqual(["child"]);
  expect(rows.some((row) => row.subagents?.some(({ id }) => id === "later"))).toBe(false);
});

test("late root seeding keeps a pending child of the root where it started, out of a later batch", () => {
  const fold = new SubagentFold();
  const replay = (update: any, acpmux: Record<string, unknown>, senderThreadId: string) => {
    seq += 1;
    const withCodex = { ...update, _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } } };
    const msg = { method: "session/update", params: { update: withCodex, _meta: { acpmux } } };
    return fold.reduce({ seq, at: seq * 1000, msg }, withCodex);
  };
  // The root's sender id is not known yet: the child is pending on it, under a stale recorded parent.
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "stale", parent: null }] }, "elsewhere");
  replay({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: "stale" }] }, "root-native");
  const childAt = seq * 1000;
  fold.closeBatch();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "later", parent: null }] });
  fold.takeRows();
  fold.setRoot("root-native");

  expect(fold.all().find(({ id }) => id === "child")?.parent).toBeNull();
  const rows = fold.takeRows();
  const withChild = rows.find((row) => row.subagents?.some(({ id }) => id === "child"));
  expect(withChild?.at).toBe(childAt);
  expect(withChild?.subagents?.map(({ id }) => id)).toEqual(["child"]);
  expect(rows.some((row) => row.subagents?.some(({ id }) => id === "later"))).toBe(false);
});

test("late root seeding never reuses the open group a phantom root emptied", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "root-native", parent: null }] });
  const phantomSeq = seq;
  fold.setRoot("root-native");
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "worker", parent: null }] });
  const workerSeq = seq;
  const rows = fold.takeRows();
  const withWorker = rows.find((row) => row.subagents?.some(({ id }) => id === "worker"));
  // The worker draws where it started, in a group of its own, not in the phantom's emptied one.
  expect(withWorker?.seq).toBe(workerSeq);
  expect(withWorker?.seq).not.toBe(phantomSeq);
});

describe("an authoritative spawnAgent parent repairs agents already recorded", () => {
  const spawnFrom = (fold: SubagentFold, senderThreadId: string, acpmux: Record<string, unknown>) => {
    seq += 1;
    const update = {
      sessionUpdate: "subagent_spawned",
      _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId } } },
    };
    const msg = { method: "session/update", params: { update, _meta: { acpmux } } };
    return fold.reduce({ seq, at: seq * 1000, msg }, update);
  };

  test("a root sender's corrected null parent un-nests a worker persisted under a stale parent", () => {
    const fold = new SubagentFold();
    // The summary names the root; an unseen sender decides no parent (``parentFor``).
    fold.setRoot("root-native");
    feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "lead", parent: null }] });
    // An older acpmux recorded the direct worker under its sibling.
    feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "worker", parent: "lead" }] });
    fold.takeRows();
    // Rust's spawn_authoritative replays it with the corrected parent: null for a root sender.
    spawnFrom(fold, "root-native", { subagents: [{ id: "worker", parent: null }] });

    expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
      ["lead", null],
      ["worker", null],
    ]);
    expect(
      fold
        .views()
        .lead?.flatMap((row) => row.subagents ?? [])
        .map(({ id }) => id) ?? [],
    ).toEqual([]);
    expect(
      fold
        .takeRows()
        .flatMap((row) => row.subagents ?? [])
        .map(({ id }) => id),
    ).toContain("worker");
  });

  test("a worker moved out of a parent view that was already drawn leaves that view", () => {
    const fold = new SubagentFold();
    fold.setRoot("root-native");
    feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "lead", parent: null }] });
    feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "worker", parent: "lead" }] });
    const ids = (rows: { subagents?: { id: string }[] }[] | undefined) =>
      rows?.flatMap((row) => row.subagents ?? []).map(({ id }) => id) ?? [];
    // The lead's view is drawn (and cached) with the worker nested in it.
    expect(ids(fold.views().lead)).toEqual(["worker"]);
    fold.takeRows();
    spawnFrom(fold, "root-native", { subagents: [{ id: "worker", parent: null }] });

    expect(ids(fold.views().lead)).toEqual([]);
    expect(ids(fold.takeRows())).toContain("worker");
    // What the lead spawns after the move still draws in its view.
    spawnFrom(fold, "lead", { subagents: [{ id: "helper", parent: "lead" }] });
    expect(ids(fold.views().lead)).toEqual(["helper"]);
  });

  test("a parent that arrives late takes the worker recorded before it", () => {
    const fold = new SubagentFold();
    // The sender's own spawn has not arrived yet: the worker is left parentless.
    spawnFrom(fold, "lead", { subagents: [{ id: "worker", parent: null }] });
    // The sender's spawn moves the worker under it (``resolvePending``); its record agrees.
    spawnFrom(fold, "root-native", { subagents: [{ id: "lead", parent: null }] });
    spawnFrom(fold, "lead", { subagents: [{ id: "worker", parent: "lead" }] });

    expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
      ["worker", "lead"],
      ["lead", null],
    ]);
    expect(
      fold
        .views()
        .lead?.flatMap((row) => row.subagents ?? [])
        .map(({ id }) => id),
    ).toEqual(["worker"]);
    const root = fold.takeRows().find((row) => row.subagents?.some(({ id }) => id === "lead"));
    expect(root?.subagents?.map(({ id }) => id)).toEqual(["lead"]);
  });

  test("a non-spawn collaboration from the root does not un-nest a grandchild", () => {
    const fold = new SubagentFold();
    spawnFrom(fold, "root-native", { subagents: [{ id: "child", parent: null }] });
    spawnFrom(fold, "child", { subagents: [{ id: "grandchild", parent: "child" }] });
    seq += 1;
    const update = {
      sessionUpdate: "subagent_progress",
      _meta: { codex: { collaboration: { tool: "wait", senderThreadId: "root-native" } } },
    };
    const msg = {
      method: "session/update",
      params: { update, _meta: { acpmux: { subagents: [{ id: "grandchild", action: "Checking" }] } } },
    };
    fold.reduce({ seq, at: seq * 1000, msg }, update);

    expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
      ["child", null],
      ["grandchild", "child"],
    ]);
  });

  test("a grandchild first met in the root's non-spawn collaboration keeps its recorded parent", () => {
    const fold = new SubagentFold();
    fold.setRoot("root-native");
    spawnFrom(fold, "root-native", { subagents: [{ id: "child", parent: null }] });
    // The root waits on a worker its child spawned; this window never held that spawn. Only a
    // spawnAgent's sender is the parent of what it lists (Rust's codex_legacy): a wait's is not.
    seq += 1;
    const update = {
      sessionUpdate: "tool_call_update",
      toolCallId: "wait-1",
      _meta: { codex: { collaboration: { tool: "wait", senderThreadId: "root-native" } } },
    };
    const msg = {
      method: "session/update",
      params: { update, _meta: { acpmux: { subagents: [{ id: "grandchild", parent: "child" }] } } },
    };
    fold.reduce({ seq, at: seq * 1000, msg }, update);

    expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([
      ["child", null],
      ["grandchild", "child"],
    ]);
  });

  // A page that starts after the sender's own spawn does not know the sender, but the record's
  // parent agrees with it: Rust wrote it from the whole history, so the grandchild stays nested.
  test("a grandchild whose sender's spawn is before the page keeps the parent its record names", () => {
    const fold = new SubagentFold();
    fold.setRoot("root-native");
    spawnFrom(fold, "child", { subagents: [{ id: "grandchild", parent: "child" }] });
    expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([["grandchild", "child"]]);
    expect(fold.takeRows().flatMap((row) => row.subagents ?? [])).toEqual([]);
  });

  test("an agent already recorded under a sender before the page is not flattened by its spawn", () => {
    const fold = new SubagentFold();
    fold.setRoot("root-native");
    // Its progress came first in the window, under the parent acpmux recorded.
    feed(fold, { sessionUpdate: "subagent_progress" }, { subagents: [{ id: "grandchild", parent: "child" }] });
    spawnFrom(fold, "child", { subagents: [{ id: "grandchild", parent: "child" }] });
    expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([["grandchild", "child"]]);
  });
});

// A root learned late can be named only as a parent: the agents recorded under it were never in
// a group row. Learning the root lifts them into the session's own group.
test("late root seeding promotes children of a root that never drew as an agent", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "helper", parent: "root-native" }] });
  expect(fold.takeRows().flatMap((row) => row.subagents ?? [])).toEqual([]);
  expect(fold.setRoot("root-native")).toBe(true);
  expect(fold.all().map(({ id, parent }) => [id, parent])).toEqual([["helper", null]]);
  expect(
    fold
      .takeRows()
      .flatMap((row) => row.subagents ?? [])
      .map(({ id }) => id),
  ).toEqual(["helper"]);
  // A root no record named changes nothing.
  expect(fold.setRoot("root-other")).toBe(false);
});
