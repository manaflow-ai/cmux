import { describe, expect, test } from "bun:test";
import {
  applyAgentStateEvent,
  agentStateEvent,
  initialPriorityState,
  priorityLanes,
} from "../src/agent-activity/priority";
import { initialActivityState, reduceActivity } from "../src/agent-activity/model";

const summary = (id: string, state: "working" | "input" | "idle" | "failed", updatedAt: number) =>
  ({
    sessionId: id,
    name: id,
    title: id,
    cwd: "/repo",
    status: state === "input" ? "waiting" : state === "working" ? "running" : "ready",
    lane: { state, since: updatedAt, error: state === "failed" ? "boom" : null },
    pendingPermissions: state === "input" ? 1 : 0,
    updatedAt,
    lastTurn: state === "failed" ? { endedAt: updatedAt, errorText: "boom" } : undefined,
    parentId: null,
    peer: null,
  }) as any;

describe("event-driven priority agent state", () => {
  test("projects hook events through the existing session/workspace binding", () => {
    const event = agentStateEvent(
      {
        kind: "created",
        sessionId: "s1",
        seq: 4,
        recordKind: "turn",
        peer: null,
        session: summary("s1", "working", 10),
      } as any,
      "workspace-7",
    );
    const state = applyAgentStateEvent(initialPriorityState(), event);
    expect(state.lanes[0]).toMatchObject({ id: "s1", workspaceId: "workspace-7", state: "working" });
  });

  test("a lane shows the daemon's masked step, never the raw prompt", () => {
    const lane = (session: object) =>
      applyAgentStateEvent(initialPriorityState(), {
        kind: "updated",
        sessionId: "s1",
        seq: 1,
        session: { ...summary("s1", "working", 10), harness: "codex", ...session },
      }).lanes[0];
    // hq#2509: acpmux masks secrets in `lane.step` before the summary leaves it. The raw prompt
    // beside it still holds the token, so the view must never fall back to it.
    const token = `gh${"p"}_${"aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234"}`;
    const raw = { turn: { prompt: `push with ${token}`, startedAt: 5 }, lastMessage: { role: "agent", text: token } };
    const masked = { state: "working", since: 5, error: null, step: "push with [github token]" };
    expect(lane({ ...raw, lane: masked })).toMatchObject({ harness: "codex", step: "push with [github token]" });
    // An acpmux from before `lane.step` shows no step rather than the raw text.
    expect(lane({ ...raw, lane: { ...masked, step: undefined } }).step).toBeNull();
  });

  test("a lane's title and error are the daemon's masked ones, never the raw prompt or error", () => {
    const token = `gh${"p"}_${"aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234"}`;
    const lane = (session: object) =>
      applyAgentStateEvent(initialPriorityState(), {
        kind: "updated",
        sessionId: "s1",
        seq: 1,
        session: { ...summary("s1", "failed", 10), title: "", lastPrompt: `push ${token}`, ...session },
      }).lanes[0];
    const raw = { lastTurn: { endedAt: 10, errorText: `401 for ${token}` } };
    const masked = {
      state: "failed",
      since: 10,
      error: "401 for [github token]",
      step: null,
      title: "push [github token]",
    };
    expect(lane({ ...raw, lane: masked })).toMatchObject({
      title: "push [github token]",
      error: "401 for [github token]",
    });
    // An acpmux from before `lane.title` shows the session's name, not its latest prompt.
    expect(lane({ ...raw, lane: { ...masked, title: undefined } }).title).toBe("s1");
  });

  test("ignores duplicate and out-of-order hook events", () => {
    const initial = applyAgentStateEvent(initialPriorityState(), {
      kind: "updated",
      sessionId: "s1",
      seq: 3,
      session: summary("s1", "working", 10),
      workspaceId: "w",
    });
    const stale = applyAgentStateEvent(initial, {
      kind: "updated",
      sessionId: "s1",
      seq: 2,
      session: summary("s1", "failed", 20),
      workspaceId: "w",
    });
    expect(stale).toEqual(initial);
  });

  test("keeps the activity state stable for stale reducer events", () => {
    const first = reduceActivity(initialActivityState(), {
      type: "agentEvent",
      event: {
        kind: "updated",
        sessionId: "s1",
        seq: 3,
        session: summary("s1", "working", 10),
        workspaceId: "w",
      },
    });
    const stale = reduceActivity(first, {
      type: "agentEvent",
      event: {
        kind: "updated",
        sessionId: "s1",
        seq: 2,
        session: summary("s1", "failed", 20),
        workspaceId: "w",
      },
    });
    expect(stale).toBe(first);
    expect(stale.priorityRevision).toBe(first.priorityRevision);
    expect(stale.priorityChangedSessionId).toBe(first.priorityChangedSessionId);
  });

  test("retains the existing workspace binding when a later hook omits it", () => {
    let state = applyAgentStateEvent(initialPriorityState(), {
      kind: "created",
      sessionId: "s1",
      seq: 1,
      session: summary("s1", "working", 10),
      workspaceId: "workspace-7",
    });
    state = applyAgentStateEvent(state, {
      kind: "updated",
      sessionId: "s1",
      seq: 2,
      session: summary("s1", "input", 20),
    });
    expect(state.lanes[0]).toMatchObject({ workspaceId: "workspace-7", state: "input" });
  });

  test("orders actionable states before idle and working states", () => {
    let state = initialPriorityState();
    for (const [id, lane, time] of [
      ["working", "working", 1],
      ["idle", "idle", 2],
      ["input", "input", 3],
      ["failed", "failed", 4],
    ] as const) {
      state = applyAgentStateEvent(state, {
        kind: "updated",
        sessionId: id,
        seq: 1,
        session: summary(id, lane, time),
        workspaceId: id,
      });
    }
    expect(priorityLanes(state).map((lane) => lane.id)).toEqual(["failed", "input", "idle", "working"]);
  });

  test("purges a session without affecting its siblings", () => {
    let state = initialPriorityState();
    state = applyAgentStateEvent(state, { kind: "created", sessionId: "a", seq: 1, session: summary("a", "idle", 1) });
    state = applyAgentStateEvent(state, { kind: "created", sessionId: "b", seq: 1, session: summary("b", "idle", 1) });
    state = applyAgentStateEvent(state, { kind: "purged", sessionId: "a", seq: 2 });
    expect(state.lanes.map((lane) => lane.id)).toEqual(["b"]);
  });
});
