import { describe, expect, test } from "bun:test";

import {
  labelsWithLiveSessions,
  liveSessionsFromFreshInstance,
  liveSessionsFromLabels,
  publicInstanceLabels,
  sanitizeLiveSessions,
} from "../app/api/devices/live-sessions";

describe("device registry live sessions", () => {
  test("keeps bounded attach summaries and orders the newest first", () => {
    const sessions = sanitizeLiveSessions([
      {
        id: "workspace-old",
        workspaceID: "workspace-old",
        title: " Older workspace ",
        status: "idle",
        lastActivityAt: 100,
      },
      {
        id: "workspace-new",
        workspaceID: "workspace-new",
        terminalID: "terminal-new",
        agentSessionID: "agent-session-new",
        title: "New workspace",
        agent: "codex",
        status: "needs_input",
        lastActivityAt: 200,
      },
    ]);

    expect(sessions.map((session) => session.id)).toEqual(["workspace-new", "workspace-old"]);
    expect(sessions[0]).toMatchObject({
      terminalID: "terminal-new",
      agentSessionID: "agent-session-new",
      agent: "codex",
      status: "needs_input",
    });
  });

  test("drops malformed records, deduplicates ids, and caps each instance", () => {
    const sessions = sanitizeLiveSessions([
      null,
      { id: "missing-fields" },
      {
        id: "bad-status",
        workspaceID: "bad-status",
        title: "Bad",
        status: "invented",
        lastActivityAt: 1,
      },
      {
        id: "impossible-date",
        workspaceID: "impossible-date",
        title: "Impossible date",
        status: "idle",
        lastActivityAt: Number.MAX_VALUE,
      },
      ...Array.from({ length: 55 }, (_, index) => ({
        id: `workspace-${index % 51}`,
        workspaceID: `workspace-${index % 51}`,
        title: `Workspace ${index}`,
        status: "working",
        lastActivityAt: index,
      })),
    ]);

    expect(sessions).toHaveLength(50);
    expect(new Set(sessions.map((session) => session.id)).size).toBe(50);
    expect(sessions[0].lastActivityAt).toBe(54);
  });

  test("uses a reserved label without exposing the storage detail", () => {
    const labels = labelsWithLiveSessions(
      { channel: "stable", liveSessions: [{ id: "forged" }] },
      [{
        id: "workspace-1",
        workspaceID: "workspace-1",
        title: "Real",
        status: "idle",
        lastActivityAt: 10,
      }],
    );

    expect(liveSessionsFromLabels(labels).map((session) => session.id)).toEqual(["workspace-1"]);
    expect(publicInstanceLabels(labels)).toEqual({ channel: "stable" });
  });

  test("truncates at complete Unicode code points", () => {
    const [session] = sanitizeLiveSessions([{
      id: "workspace-1",
      workspaceID: "workspace-1",
      title: `${"a".repeat(159)}🚀trailing`,
      agent: `${"b".repeat(31)}🚀trailing`,
      status: "working",
      lastActivityAt: 10,
    }]);

    expect(Array.from(session.title)).toHaveLength(160);
    expect(Array.from(session.title).at(-1)).toBe("🚀");
    expect(Array.from(session.agent ?? "")).toHaveLength(32);
    expect(Array.from(session.agent ?? "").at(-1)).toBe("🚀");
  });

  test("returns session advertisements only inside the runtime lease", () => {
    const labels = labelsWithLiveSessions({}, [{
      id: "workspace-1",
      workspaceID: "workspace-1",
      title: "Fresh",
      status: "idle",
      lastActivityAt: 10,
    }]);
    const now = new Date("2026-07-14T20:00:00.000Z");

    expect(liveSessionsFromFreshInstance(
      labels,
      new Date("2026-07-14T19:58:00.000Z"),
      now,
    )).toHaveLength(1);
    expect(liveSessionsFromFreshInstance(
      labels,
      new Date("2026-07-14T19:57:59.999Z"),
      now,
    )).toEqual([]);
  });
});
