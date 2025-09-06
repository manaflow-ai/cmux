import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170005";

describe("taskRunLogChunks queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("appendChunk and getChunks", async () => {
    const t = convexTest(schema, modules);
    const userId = "u1";
    // Seed membership and a task + run
    let runId!: import("./_generated/dataModel").Id<"taskRuns">;
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now });
      const taskId = await ctx.db.insert("tasks", { text: "t", isCompleted: false, userId, teamId: TEAM_ID, createdAt: now, updatedAt: now });
      runId = await ctx.db.insert("taskRuns", { taskId, prompt: "p", status: "pending", log: "", createdAt: now, updatedAt: now, userId, teamId: TEAM_ID });
    });
    const asUser = t.withIdentity({ subject: userId });

    await asUser.mutation(api.taskRunLogChunks.appendChunk, { teamSlugOrId: TEAM_ID, taskRunId: runId, content: "hello" });
    await asUser.mutation(api.taskRunLogChunks.appendChunkPublic, { teamSlugOrId: TEAM_ID, taskRunId: runId, content: " world" });
    const chunks = await asUser.query(api.taskRunLogChunks.getChunks, { teamSlugOrId: TEAM_ID, taskRunId: runId });
    expect(chunks.map((c) => c.content).join("")).toBe("hello world");
  });
});
