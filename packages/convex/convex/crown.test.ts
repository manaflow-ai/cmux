import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170008";

describe("crown queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("evaluateAndCrownWinner single vs multi-run path; setCrownWinner/getters", async () => {
    const t = convexTest(schema, modules);
    const userId = "u1";
    let taskId!: import("./_generated/dataModel").Id<"tasks">;
    let run1!: import("./_generated/dataModel").Id<"taskRuns">;
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now });
      taskId = await ctx.db.insert("tasks", { text: "T", isCompleted: false, userId, teamId: TEAM_ID, createdAt: now, updatedAt: now });
      run1 = await ctx.db.insert("taskRuns", { taskId, prompt: "p1", status: "completed", log: "", createdAt: now, updatedAt: now, userId, teamId: TEAM_ID });
    });
    const asUser = t.withIdentity({ subject: userId });

    // single completed run -> crowned by default
    const singleWinner = await asUser.mutation(api.crown.evaluateAndCrownWinner, { teamSlugOrId: TEAM_ID, taskId });
    expect(singleWinner).toBe(run1);

    // add second completed run -> evaluate returns pending and marks task
    const run2 = await t.run(async (ctx) => {
      return await ctx.db.insert("taskRuns", { taskId, prompt: "p2", status: "completed", log: "", createdAt: Date.now(), updatedAt: Date.now(), userId, teamId: TEAM_ID });
    });
    const status = await asUser.mutation(api.crown.evaluateAndCrownWinner, { teamSlugOrId: TEAM_ID, taskId });
    expect(status).toBe("pending");

    // Select a winner explicitly
    const crowned = await asUser.mutation(api.crown.setCrownWinner, { teamSlugOrId: TEAM_ID, taskRunId: run2, reason: "better" });
    expect(crowned).toBe(run2);

    const foundRun = await asUser.query(api.crown.getCrownedRun, { teamSlugOrId: TEAM_ID, taskId });
    expect(foundRun?._id).toBe(run2);
    const evaluation = await asUser.query(api.crown.getCrownEvaluation, { teamSlugOrId: TEAM_ID, taskId });
    expect(evaluation?.winnerRunId).toBe(run2);
  });
});
