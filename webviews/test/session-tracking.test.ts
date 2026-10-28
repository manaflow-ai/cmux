import { describe, expect, test } from "bun:test";
import { sessionTrackingRows } from "../src/agent-session/acpmux/summary/sessionTracking";

describe("sessions projected onto workflow rows", () => {
  test("includes peers and archived/closed sessions without joining repeated names", () => {
    const rows = sessionTrackingRows(
      [
        { sessionId: "one", name: "review", status: "running", lane: { state: "working" } },
        {
          sessionId: "one",
          name: "review",
          peer: "fixture-worker",
          status: "closed",
          tags: { archived: "1" },
        },
      ],
      { localHost: "fixture-desktop" },
    );
    expect(rows).toHaveLength(2);
    expect(rows[0]!.agent.id).not.toBe(rows[1]!.agent.id);
    expect(rows.map((row) => [row.host, row.agent.state])).toEqual([
      ["fixture-desktop", "running"],
      ["fixture-worker", "unknown"],
    ]);
    expect(rows.every((row) => row.agent.agentId === undefined)).toBe(true);
  });

  test.each([
    ["working", "running"],
    ["input", "waiting"],
    ["idle", "unknown"],
    ["ready", "unknown"],
    ["failed", "failed"],
    ["lost", "failed"],
    ["stuck", "failed"],
    ["pending", "pending"],
    ["paused", "paused"],
    ["completed", "completed"],
    ["cancelled", "cancelled"],
    ["future-state", "unknown"],
  ])("maps reported %s to %s without declaring idle work completed", (source, expected) => {
    const [row] = sessionTrackingRows([{ sessionId: "s", state: source }]);
    expect(row!.sourceState).toBe(source);
    expect(row!.agent.state).toBe(expected);
  });

  test("keeps a reported stuck reason and area, overriding an older running status", () => {
    const [row] = sessionTrackingRows([
      {
        sessionId: "s",
        qualifiedSessionId: "fixture-worker/s",
        peer: "fixture-worker",
        status: "running",
        state: "stuck",
        stuckReason: "Provider unavailable",
        tags: { area: "Search" },
        lane: { state: "working" },
      },
    ]);
    expect(row).toMatchObject({
      host: "fixture-worker",
      area: "Search",
      sourceState: "stuck",
      stuckReason: "Provider unavailable",
      agent: { state: "failed", retryReason: "Provider unavailable" },
    });
  });

  test.each(["unreachable", "disconnected", "closed"])(
    "%s cannot retain a mirrored working state",
    (status) => {
      const [row] = sessionTrackingRows([{ sessionId: "s", status, lane: { state: "working" } }]);
      expect(row!.agent.state).toBe("unknown");
      expect(row!.agent.startedAt).toBeUndefined();
    },
  );

  test("a stale peer is unknown and a delayed resolve cannot restore running", () => {
    const [row] = sessionTrackingRows(
      [
        {
          sessionId: "s",
          qualifiedSessionId: "fixture-worker/s",
          stale: true,
          lane: { state: "working" },
        },
      ],
      {
        resolved: [
          {
            sessionId: "s",
            qualifiedSessionId: "fixture-worker/s",
            host: "fixture-worker",
            status: "running",
          },
        ],
      },
    );
    expect(row!.agent.state).toBe("unknown");
    expect(row!.host).toBe("fixture-worker");
  });

  test("resolve supplies PR history only for an unambiguous exact session identity", () => {
    const url = "https://github.com/example/project/pull/12";
    const sessions = [
      { sessionId: "s", name: "review", qualifiedSessionId: "fixture-worker/s" },
      { sessionId: "other", name: "review", qualifiedSessionId: "fixture-worker/other" },
    ];
    const match = { ...sessions[0]!, host: "fixture-worker", pullRequests: [url, url] };
    const rows = sessionTrackingRows(sessions, { resolved: [match] });
    expect(rows[0]!.pullRequests).toEqual([url]);
    expect(rows[0]!.currentPullRequest).toBeUndefined();
    expect(rows[1]!.pullRequests).toEqual([]);
    expect(sessionTrackingRows(sessions, { resolved: [match, match] })[0]!.pullRequests).toEqual(
      [],
    );
    expect(
      sessionTrackingRows(sessions, { resolved: [{ ...match, sessionId: "different" }] })[0]!
        .pullRequests,
    ).toEqual([]);
  });

  test("an explicit empty PR list supersedes an older resolve result", () => {
    const [row] = sessionTrackingRows([{ sessionId: "s", pullRequests: [] }], {
      resolved: [{ sessionId: "s", pullRequests: ["https://github.com/example/project/pull/12"] }],
    });
    expect(row!.pullRequests).toEqual([]);
  });

  test("retains the daemon's current branch PR separately from recorded history", () => {
    const current = { number: 15, title: "Improve search", state: "draft", checks: "pending" };
    const [row] = sessionTrackingRows([
      {
        sessionId: "s",
        pullRequest: current,
        pullRequests: ["https://github.com/example/project/pull/12"],
      },
    ]);
    expect(row!.currentPullRequest).toMatchObject(current);
    expect(row!.pullRequests).toEqual(["https://github.com/example/project/pull/12"]);
  });

  test("running elapsed time starts at the current turn, never at session creation", () => {
    const sessions = [
      {
        sessionId: "s",
        status: "running",
        createdAt: 1,
        turn: { startedAt: 1200 },
        model: "fixture-model",
      },
      { sessionId: "missing", status: "running", createdAt: 1 },
      { sessionId: "idle", status: "idle", turn: { startedAt: 1200 } },
    ];
    const rows = sessionTrackingRows(sessions);
    expect(rows[0]!.agent).toMatchObject({ startedAt: 1200, model: "fixture-model" });
    expect(rows[1]!.agent.startedAt).toBeUndefined();
    expect(rows[2]!.agent.startedAt).toBeUndefined();
  });

  test("missing metadata stays unknown; prompts, paths and names never supply an area", () => {
    const [row] = sessionTrackingRows([
      { sessionId: "s", name: "search-helper", cwd: "/work/search", lastPrompt: "secret prompt" },
    ]);
    expect(row!.host).toBeUndefined();
    expect(row!.area).toBeUndefined();
    expect(row!.agent.name).toBe("search-helper");
    expect(row!.agent.state).toBe("unknown");
    expect(JSON.stringify(row)).not.toContain("secret prompt");
    expect(sessionTrackingRows([])).toEqual([]);
  });
});
