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
  });
});
