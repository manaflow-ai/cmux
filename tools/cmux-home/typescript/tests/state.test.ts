import { describe, expect, test } from "bun:test";
import { adapterCounts, groupSessionsByStatus, parseHomeState, statusCounts } from "../src/state";

describe("home state parsing", () => {
  test("parses direct sessions and normalizes statuses", () => {
    const state = parseHomeState({
      sessions: [
        {
          id: "one",
          agent: "Claude Code",
          session_id: "claude-1",
          status: "needs-input",
          title: "Approve plan",
          cwd: "/repo",
        },
        {
          id: "two",
          agent: "codex",
          sessionId: "codex-1",
          state: "in progress",
          summary: "Implement parser",
        },
      ],
    });

    expect(state.sessions).toHaveLength(2);
    expect(state.sessions[0]?.adapter).toBe("claude");
    expect(state.sessions[0]?.status).toBe("awaiting");
    expect(state.sessions[1]?.status).toBe("working");
  });

  test("loads workspace nested sessions with inherited cwd and branch", () => {
    const state = parseHomeState({
      workspaces: [
        {
          cwd: "/repo/cmux",
          branch: "feat-home",
          panels: [
            {
              id: "panel-1",
              terminal: {
                agent: {
                  kind: "opencode",
                  sessionId: "open-1",
                  status: "idle",
                  title: "Search OpenCode history",
                },
              },
            },
          ],
        },
      ],
    });

    expect(state.sessions).toHaveLength(1);
    expect(state.sessions[0]?.cwd).toBe("/repo/cmux");
    expect(state.sessions[0]?.branch).toBe("feat-home");
    expect(state.sessions[0]?.resumeCommand).toBe("cd /repo/cmux && opencode --session open-1");
  });

  test("groups and counts sessions by status and adapter", () => {
    const state = parseHomeState({
      sessions: [
        { agent: "pi", sessionId: "pi-1", status: "done", title: "Done" },
        { agent: "codex", sessionId: "codex-1", status: "running", title: "Run" },
        { agent: "claude", sessionId: "claude-1", status: "waiting", title: "Wait" },
      ],
    });

    expect(adapterCounts(state.sessions)).toEqual({ claude: 1, codex: 1, opencode: 0, pi: 1 });
    expect(statusCounts(state.sessions).working).toBe(1);
    expect(groupSessionsByStatus(state.sessions).map((group) => [group.status, group.sessions.length])).toEqual([
      ["awaiting", 1],
      ["working", 1],
      ["completed", 1],
    ]);
  });

  test("parses shared cmux home schema fields", () => {
    const state = parseHomeState({
      sessions: [
        {
          id: "codex:codex-permission-17",
          agent: "codex",
          agentSessionId: "codex-permission-17",
          title: "Fix auth callback race",
          status: "awaiting",
          summary: "Codex is waiting for a shell permission decision.",
          updatedAt: "2026-05-12T15:57:44Z",
          workspace: {
            cwd: "/Users/example/src/cmux",
            git: { branch: "feat-auth-callback" },
          },
          activity: {
            phase: "awaitingUser",
            lastMessage: "Permission request for test command.",
          },
          resume: {
            command: ["codex", "resume", "codex-permission-17"],
          },
        },
      ],
    });

    expect(state.sessions[0]?.status).toBe("awaiting");
    expect(state.sessions[0]?.sessionId).toBe("codex-permission-17");
    expect(state.sessions[0]?.cwd).toBe("/Users/example/src/cmux");
    expect(state.sessions[0]?.branch).toBe("feat-auth-callback");
    expect(state.sessions[0]?.preview).toBe("Permission request for test command.");
    expect(state.sessions[0]?.details).toBe("Codex is waiting for a shell permission decision.");
    expect(state.sessions[0]?.resumeCommand).toBe("codex resume codex-permission-17");
  });

  test("prefers canonical agentSessionId over legacy sessionId", () => {
    const state = parseHomeState({
      sessions: [
        {
          id: "codex:canonical",
          agent: "codex",
          sessionId: "legacy",
          agentSessionId: "canonical",
          title: "Canonical",
          status: "working",
        },
      ],
    });

    expect(state.sessions[0]?.sessionId).toBe("canonical");
  });

  test("rejects unsupported schema versions", () => {
    expect(() => parseHomeState({ schemaVersion: 2, sessions: [] })).toThrow(/schemaVersion/);
  });

  test("rejects schema statuses outside the shared contract", () => {
    expect(() => parseHomeState({
      schemaVersion: 1,
      sessions: [
        { id: "bad", agent: "codex", agentSessionId: "bad", status: "failed" },
      ],
    })).toThrow(/status/);
  });
});
