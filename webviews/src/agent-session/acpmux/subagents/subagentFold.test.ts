import { describe, expect, test } from "bun:test";
import { SUBAGENTS, SubagentFold, stopReasonOf, subagentStops } from "./subagentFold";

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
