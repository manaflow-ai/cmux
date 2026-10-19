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

  test("a lane carries its harness and its current step", () => {
    const step = (session: object) =>
      applyAgentStateEvent(initialPriorityState(), {
        kind: "updated",
        sessionId: "s1",
        seq: 1,
        session: { ...summary("s1", "working", 10), harness: "codex", ...session },
      }).lanes[0];
    // A running turn's step is its prompt, whitespace folded to one line.
    expect(
      step({ turn: { prompt: "Run the guard\n  tests", startedAt: 5 }, lastMessage: { role: "agent", text: "old" } }),
    ).toMatchObject({ harness: "codex", step: "Run the guard tests" });
    // Between turns it is the agent's last message; a person's own message says nothing new.
    expect(step({ lastMessage: { role: "agent", text: "Opened #21700" } }).step).toBe("Opened #21700");
    expect(step({ lastMessage: { role: "user", text: "go" } }).step).toBeNull();
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
