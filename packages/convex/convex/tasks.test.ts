import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170006";

describe("tasks queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("create/get/update/toggle/setCompleted/archive/unarchive", async () => {
    const t = convexTest(schema, modules);
    const userId = "u1";
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: userId });

    const id = await asUser.mutation(api.tasks.create, {
      teamSlugOrId: TEAM_ID,
      text: "Task 1",
      description: "desc",
      projectFullName: "org/repo",
    });

    // get list
    const list = await asUser.query(api.tasks.get, { teamSlugOrId: TEAM_ID, projectFullName: "org/repo" });
    expect(list.length).toBe(1);

    // getById
    const got = await asUser.query(api.tasks.getById, { teamSlugOrId: TEAM_ID, id });
    expect(got?.text).toBe("Task 1");

    // update
    await asUser.mutation(api.tasks.update, { teamSlugOrId: TEAM_ID, id, text: "Task 1 updated" });
    const upd = await asUser.query(api.tasks.getById, { teamSlugOrId: TEAM_ID, id });
    expect(upd?.text).toBe("Task 1 updated");

    // toggle and setCompleted
    await asUser.mutation(api.tasks.toggle, { teamSlugOrId: TEAM_ID, id });
    let afterToggle = await asUser.query(api.tasks.getById, { teamSlugOrId: TEAM_ID, id });
    expect(afterToggle?.isCompleted).toBe(true);
    await asUser.mutation(api.tasks.setCompleted, { teamSlugOrId: TEAM_ID, id, isCompleted: false });
    afterToggle = await asUser.query(api.tasks.getById, { teamSlugOrId: TEAM_ID, id });
    expect(afterToggle?.isCompleted).toBe(false);

    // archive/unarchive
    await asUser.mutation(api.tasks.archive, { teamSlugOrId: TEAM_ID, id });
    let archived = await asUser.query(api.tasks.get, { teamSlugOrId: TEAM_ID, archived: true });
    expect(archived.length).toBe(1);
    await asUser.mutation(api.tasks.unarchive, { teamSlugOrId: TEAM_ID, id });
    archived = await asUser.query(api.tasks.get, { teamSlugOrId: TEAM_ID, archived: true });
    expect(archived.length).toBe(0);

    // remove
    await asUser.mutation(api.tasks.remove, { teamSlugOrId: TEAM_ID, id });
    const afterRemove = await asUser.query(api.tasks.get, { teamSlugOrId: TEAM_ID });
    expect(afterRemove.length).toBe(0);
  });

  test("createVersion/getVersions/pull request fields/merge status/crown error", async () => {
    const t = convexTest(schema, modules);
    const userId = "u2";
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: userId });

    const id = await asUser.mutation(api.tasks.create, { teamSlugOrId: TEAM_ID, text: "Task 2" });
    await asUser.mutation(api.tasks.setPullRequestTitle, { teamSlugOrId: TEAM_ID, id, pullRequestTitle: "PR title" });
    await asUser.mutation(api.tasks.setPullRequestDescription, { teamSlugOrId: TEAM_ID, id, pullRequestDescription: "PR desc" });
    await asUser.mutation(api.tasks.updateMergeStatus, { teamSlugOrId: TEAM_ID, id, mergeStatus: "pr_open" });
    await asUser.mutation(api.tasks.updateCrownError, { teamSlugOrId: TEAM_ID, id, crownEvaluationError: "oops" });

    const got = await asUser.query(api.tasks.getById, { teamSlugOrId: TEAM_ID, id });
    expect(got?.pullRequestTitle).toBe("PR title");
    expect(got?.pullRequestDescription).toBe("PR desc");
    expect(got?.mergeStatus).toBe("pr_open");
    expect(got?.crownEvaluationError).toBe("oops");

    const v1 = await asUser.mutation(api.tasks.createVersion, {
      teamSlugOrId: TEAM_ID,
      taskId: id,
      diff: "diff",
      summary: "sum",
      files: [{ path: "a.txt", changes: "+1" }],
    });
    const versions = await asUser.query(api.tasks.getVersions, { teamSlugOrId: TEAM_ID, taskId: id });
    expect(versions.length).toBe(1);
    expect(versions[0]._id).toBe(v1);
  });

  test("getTasksWithPendingCrownEvaluation filters tasks without existing evaluation", async () => {
    const t = convexTest(schema, modules);
    const userId = "u3";
    let taskId!: import("./_generated/dataModel").Id<"tasks">;
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now });
      taskId = await ctx.db.insert("tasks", { text: "T", isCompleted: false, crownEvaluationError: "pending_evaluation", userId, teamId: TEAM_ID, createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: userId });

    // No evaluation yet -> returned
    const list1 = await asUser.query(api.tasks.getTasksWithPendingCrownEvaluation, { teamSlugOrId: TEAM_ID });
    expect(list1.map((t) => t._id)).toContain(taskId);

    // Create evaluation -> filtered out
    await t.run(async (ctx) => {
      const runId = await ctx.db.insert("taskRuns", {
        taskId,
        prompt: "p",
        status: "completed",
        log: "",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        userId,
        teamId: TEAM_ID,
      });
      await ctx.db.insert("crownEvaluations", {
        taskId,
        evaluatedAt: Date.now(),
        winnerRunId: runId,
        candidateRunIds: [runId],
        evaluationPrompt: "p",
        evaluationResponse: "r",
        createdAt: Date.now(),
        userId,
        teamId: TEAM_ID,
      });
    });
    const list2 = await asUser.query(api.tasks.getTasksWithPendingCrownEvaluation, { teamSlugOrId: TEAM_ID });
    expect(list2.map((t) => t._id)).not.toContain(taskId);
  });
});
