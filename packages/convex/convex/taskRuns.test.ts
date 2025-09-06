import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api, internal } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170007";

describe("taskRuns queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("happy-path flow: create, mutate, and query task runs", async () => {
    const t = convexTest(schema, modules);
    const userId = "u1";

    // Seed team membership and a task
    let taskId!: import("./_generated/dataModel").Id<"tasks">;
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now });
      taskId = await ctx.db.insert("tasks", { text: "T", isCompleted: false, userId, teamId: TEAM_ID, createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: userId });

    // create
    const runId: import("./_generated/dataModel").Id<"taskRuns"> = await asUser.mutation(api.taskRuns.create, { teamSlugOrId: TEAM_ID, taskId, prompt: "p1" });
    // getByTask (tree)
    const tree = await asUser.query(api.taskRuns.getByTask, { teamSlugOrId: TEAM_ID, taskId });
    expect(tree.length).toBe(1);
    expect(tree[0]._id).toBe(runId);

    // internal: updateStatus -> running
    await t.mutation(internal.taskRuns.updateStatus, { id: runId, status: "running" });
    let after = await asUser.query(api.taskRuns.get, { teamSlugOrId: TEAM_ID, id: runId });
    expect(after?.status).toBe("running");

    // internal: appendLog
    await t.mutation(internal.taskRuns.appendLog, { id: runId, content: "hello" });
    after = await asUser.query(api.taskRuns.get, { teamSlugOrId: TEAM_ID, id: runId });
    expect(after?.log).toBe("hello");

    // auth: updateSummary
    await asUser.mutation(api.taskRuns.updateSummary, { teamSlugOrId: TEAM_ID, id: runId, summary: "sum" });
    after = await asUser.query(api.taskRuns.get, { teamSlugOrId: TEAM_ID, id: runId });
    expect(after?.summary).toBe("sum");

    // get & subscribe equivalent shape
    const sub = await asUser.query(api.taskRuns.subscribe, { teamSlugOrId: TEAM_ID, id: runId });
    expect(sub?._id).toBe(runId);

    // internal: updateExitCode
    await t.mutation(internal.taskRuns.updateExitCode, { id: runId, exitCode: 5 });
    after = await asUser.query(api.taskRuns.get, { teamSlugOrId: TEAM_ID, id: runId });
    expect(after?.exitCode).toBe(5);

    // auth: updateWorktreePath
    await asUser.mutation(api.taskRuns.updateWorktreePath, { teamSlugOrId: TEAM_ID, id: runId, worktreePath: "/wt" });
    after = await asUser.query(api.taskRuns.get, { teamSlugOrId: TEAM_ID, id: runId });
    expect(after?.worktreePath).toBe("/wt");

    // public status update to completed with exitCode
    await asUser.mutation(api.taskRuns.updateStatusPublic, { teamSlugOrId: TEAM_ID, id: runId, status: "completed", exitCode: 0 });
    after = await asUser.query(api.taskRuns.get, { teamSlugOrId: TEAM_ID, id: runId });
    expect(after?.status).toBe("completed");
    expect(after?.completedAt).toBeDefined();

    // public append log
    await asUser.mutation(api.taskRuns.appendLogPublic, { teamSlugOrId: TEAM_ID, id: runId, content: "!" });
    after = await asUser.query(api.taskRuns.get, { teamSlugOrId: TEAM_ID, id: runId });
    expect(after?.log.endsWith("!")).toBe(true);

    // VSCode instance: set instance, status and ports
    await asUser.mutation(api.taskRuns.updateVSCodeInstance, {
      teamSlugOrId: TEAM_ID,
      id: runId,
      vscode: { provider: "docker", status: "starting", containerName: "c1" },
    });
    await asUser.mutation(api.taskRuns.updateVSCodeStatus, { teamSlugOrId: TEAM_ID, id: runId, status: "running" });
    await asUser.mutation(api.taskRuns.updateVSCodePorts, {
      teamSlugOrId: TEAM_ID,
      id: runId,
      ports: { vscode: "1234", worker: "5678" },
    });

    // getByContainerName
    const byName = await asUser.query(api.taskRuns.getByContainerName, { teamSlugOrId: TEAM_ID, containerName: "c1" });
    expect(byName?._id).toBe(runId);

    // complete and fail on separate runs
    const run2: import("./_generated/dataModel").Id<"taskRuns"> = await asUser.mutation(api.taskRuns.create, { teamSlugOrId: TEAM_ID, taskId, prompt: "p2" });
    await asUser.mutation(api.taskRuns.complete, { teamSlugOrId: TEAM_ID, id: run2, exitCode: 0 });
    const run3: import("./_generated/dataModel").Id<"taskRuns"> = await asUser.mutation(api.taskRuns.create, { teamSlugOrId: TEAM_ID, taskId, prompt: "p3" });
    await asUser.mutation(api.taskRuns.fail, { teamSlugOrId: TEAM_ID, id: run3, errorMessage: "boom" });

    // getActiveVSCodeInstances
    const active = await asUser.query(api.taskRuns.getActiveVSCodeInstances, { teamSlugOrId: TEAM_ID });
    expect(active.some((r) => r._id === runId)).toBe(true);

    // access/keep alive/scheduled stop
    await asUser.mutation(api.taskRuns.updateLastAccessed, { teamSlugOrId: TEAM_ID, id: runId });
    await asUser.mutation(api.taskRuns.toggleKeepAlive, { teamSlugOrId: TEAM_ID, id: runId, keepAlive: true });
    await asUser.mutation(api.taskRuns.updateScheduledStop, { teamSlugOrId: TEAM_ID, id: runId, scheduledStopAt: Date.now() + 1000 });

    // PR and networking
    await asUser.mutation(api.taskRuns.updatePullRequestUrl, { teamSlugOrId: TEAM_ID, id: runId, pullRequestUrl: "http://pr", state: "open", number: 1 });
    await asUser.mutation(api.taskRuns.updatePullRequestState, { teamSlugOrId: TEAM_ID, id: runId, state: "merged", isDraft: false, number: 1, url: "http://pr" });
    await asUser.mutation(api.taskRuns.updateNetworking, { teamSlugOrId: TEAM_ID, id: runId, networking: [{ status: "running", port: 8080, url: "http://x" }] });

    // Container stop queries
    // Ensure settings present to enable cleanup and keep 1 container
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("containerSettings", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now, autoCleanupEnabled: true, minContainersToKeep: 1 });
    });

    // Create two running containers with scheduledStopAt times
    const runA: import("./_generated/dataModel").Id<"taskRuns"> = await asUser.mutation(api.taskRuns.create, { teamSlugOrId: TEAM_ID, taskId, prompt: "pa" });
    await asUser.mutation(api.taskRuns.updateVSCodeInstance, { teamSlugOrId: TEAM_ID, id: runA, vscode: { provider: "docker", status: "running", containerName: "ca" } });
    await asUser.mutation(api.taskRuns.updateScheduledStop, { teamSlugOrId: TEAM_ID, id: runA, scheduledStopAt: Date.now() - 10 });

    const runB: import("./_generated/dataModel").Id<"taskRuns"> = await asUser.mutation(api.taskRuns.create, { teamSlugOrId: TEAM_ID, taskId, prompt: "pb" });
    await asUser.mutation(api.taskRuns.updateVSCodeInstance, { teamSlugOrId: TEAM_ID, id: runB, vscode: { provider: "docker", status: "running", containerName: "cb" } });
    await asUser.mutation(api.taskRuns.updateScheduledStop, { teamSlugOrId: TEAM_ID, id: runB, scheduledStopAt: Date.now() - 5 });

    const toStop = await asUser.query(api.taskRuns.getContainersToStop, { teamSlugOrId: TEAM_ID });
    expect(Array.isArray(toStop)).toBe(true);

    const priority = await asUser.query(api.taskRuns.getRunningContainersByCleanupPriority, { teamSlugOrId: TEAM_ID });
    expect(priority.total).toBeGreaterThan(0);
    expect(Array.isArray(priority.prioritizedForCleanup)).toBe(true);
  });
});
