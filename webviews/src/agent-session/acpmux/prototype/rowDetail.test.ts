import { describe, expect, test } from "bun:test";
import { mockSessions, sessionSummary } from "../mockFixture";
import { sessionEntry, type AcpmuxSessionEntry } from "../sessionList";
import { groupByStatus, rowDetailItems, rowDetailLevel, workspaceDetail } from "./rowDetail";
import { seedStack } from "./workspaces";

const now = Date.UTC(2026, 9, 1, 12);
const sessions = new Map(
  mockSessions.map((session) => [
    session.sessionId,
    sessionEntry(sessionSummary(session, now, 1) as AcpmuxSessionEntry),
  ]),
);
const seeded = (id: string) => seedStack.workspaces.find((workspace) => workspace.id === id)!;

describe("sidebar row detail", () => {
  test("the default row is minimal, and an unknown level falls back to it", () => {
    expect(rowDetailLevel(undefined)).toBe("minimal");
    expect(rowDetailLevel("maximal")).toBe("minimal");
    expect(Object.values(rowDetailItems("minimal")).some(Boolean)).toBe(false);
  });

  test("a level is a preset that per-item toggles override either way", () => {
    expect(rowDetailItems("standard")).toEqual({
      preview: true,
      pullRequest: true,
      branch: false,
      agents: false,
      groupByStatus: false,
    });
    expect(rowDetailItems("minimal", { agents: true }).agents).toBe(true);
    expect(rowDetailItems("everything", { groupByStatus: false })).toMatchObject({
      groupByStatus: false,
      branch: true,
    });
  });

  test("classic cmux forces the minimal row over the level and every toggle", () => {
    const items = rowDetailItems("everything", { preview: true, agents: true }, "terminal");
    expect(Object.values(items).some(Boolean)).toBe(false);
  });

  test("a workspace's detail lists every agent tab with its status, most urgent first for the row", () => {
    const detail = workspaceDetail(seeded("ws-tabstrip"), sessions, now);
    expect(detail.agents.map((agent) => [agent.harness, agent.status])).toEqual([
      ["claude", "input"],
      ["codex", "error"],
    ]);
    expect(detail.status).toBe("input");
    expect(detail.preview?.age).toBe("9m");
  });

  test("the preview, branch and pull request come from the lead session, or another agent's PR", () => {
    const uploader = workspaceDetail(seeded("ws-uploader"), sessions, now);
    expect(uploader.branch).toBe("feat-upload-retry");
    expect(uploader.pullRequest).toMatchObject({ number: 18204, checks: "passing" });
    expect(uploader.preview?.text).toBe("Uploads now retry server errors with backoff.");
    // A workspace without an agent has nothing to detail.
    expect(workspaceDetail(seeded("ws-dev"), sessions, now)).toEqual({ agents: [], status: "idle" } as never);
  });

  test("group by status keeps stack order inside a group and drops empty groups", () => {
    const rows = seedStack.workspaces.map((workspace) => ({
      id: workspace.id,
      status: workspaceDetail(workspace, sessions, now).status,
    }));
    const groups = groupByStatus(rows, (row) => row.status);
    expect(groups.map((group) => [group.label, group.items.length])).toEqual([
      ["Needs input", 2],
      ["Working", 2],
      ["Idle", 4],
    ]);
    expect(groups[0]!.items.map((row) => row.id)).toEqual(["ws-tabstrip", "ws-home"]);
  });
});
