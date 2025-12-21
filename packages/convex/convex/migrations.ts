// To run migrations:
// bunx convex run migrations:run '{fn: "migrations:setDefaultValue"}'
//
// For backfillTaskRunPullRequests:
// bunx convex run migrations:backfillTaskRunPullRequests

import { v } from "convex/values";
import { Migrations } from "@convex-dev/migrations";
import { internalMutation } from "./_generated/server";
import { components, internal } from "./_generated/api";
import type { DataModel } from "./_generated/dataModel";

export const migrations = new Migrations<DataModel>(components.migrations);

// Backfill teams.teamId from legacy teams.uuid when missing
export const backfillTeamsTeamId = migrations.define({
  table: "teams",
  migrateOne: (_ctx, doc) => {
    const d = doc as unknown as { teamId?: string } & Record<string, unknown>;
    if (d.teamId === undefined) {
      const legacy = (d as Record<string, unknown>)["uuid"];
      if (typeof legacy === "string") {
        return { teamId: legacy } as Partial<typeof doc>;
      }
    }
  },
});

// Backfill users.userId from legacy users.uuid when missing
export const backfillUsersUserId = migrations.define({
  table: "users",
  migrateOne: (_ctx, doc) => {
    const d = doc as unknown as { userId?: string } & Record<string, unknown>;
    if (d.userId === undefined) {
      const legacy = (d as Record<string, unknown>)["uuid"];
      if (typeof legacy === "string") {
        return { userId: legacy } as Partial<typeof doc>;
      }
    }
  },
});

export const dropUsersUuid = migrations.define({
  table: "users",
  migrateOne: (_ctx, doc) => {
    return { userId: doc.userId, uuid: undefined } as Partial<typeof doc>;
  },
});

export const dropTeamsUuid = migrations.define({
  table: "teams",
  migrateOne: (_ctx, doc) => {
    return { teamId: doc.teamId, uuid: undefined } as Partial<typeof doc>;
  },
});

// Remove deprecated CLI output logs retained on historical task runs
export const clearTaskRunsLog = migrations.define({
  table: "taskRuns",
  migrateOne: (_ctx, doc) => {
    if (doc.log === undefined) {
      return;
    }
    return { log: undefined };
  },
});

// Remove deprecated createdByUserId from previewConfigs (quota now team-based)
export const dropPreviewConfigsCreatedByUserId = migrations.define({
  table: "previewConfigs",
  migrateOne: (_ctx, doc) => {
    const d = doc as unknown as { createdByUserId?: string } & Record<string, unknown>;
    if (d.createdByUserId !== undefined) {
      return { createdByUserId: undefined } as Partial<typeof doc>;
    }
  },
});

// Remove deprecated createdByUserId from previewRuns (quota now team-based)
export const dropPreviewRunsCreatedByUserId = migrations.define({
  table: "previewRuns",
  migrateOne: (_ctx, doc) => {
    const d = doc as unknown as { createdByUserId?: string } & Record<string, unknown>;
    if (d.createdByUserId !== undefined) {
      return { createdByUserId: undefined } as Partial<typeof doc>;
    }
  },
});

// Generic runner; choose migrations from CLI or dashboard when invoking
export const run = migrations.runner();

/**
 * Backfill the taskRunPullRequests junction table from existing taskRuns.pullRequests arrays.
 * This is a one-time migration to populate the junction table for efficient PR webhook lookups.
 *
 * Run with: bunx convex run migrations:backfillTaskRunPullRequests
 *
 * This schedules itself to continue processing if there are more documents,
 * avoiding the 16MB read limit per function execution.
 * It's idempotent - running it multiple times won't create duplicate entries.
 */
export const backfillTaskRunPullRequests = internalMutation({
  handler: async (ctx) => {
    let totalProcessed = 0;
    let totalInserted = 0;
    const batchSize = 50; // Small batch to stay under limits

    const results = await ctx.db
      .query("taskRuns")
      .paginate({ cursor: null, numItems: batchSize });

    for (const run of results.page) {
      if (!run.pullRequests || run.pullRequests.length === 0) {
        continue;
      }

      for (const pr of run.pullRequests) {
        if (pr.number === undefined) {
          continue;
        }

        // Check if entry already exists by querying the junction table
        // We query by the unique combination of taskRunId + PR identity
        const existingEntries = await ctx.db
          .query("taskRunPullRequests")
          .withIndex("by_task_run", (q) => q.eq("taskRunId", run._id))
          .collect();

        const alreadyExists = existingEntries.some(
          (e) =>
            e.repoFullName === pr.repoFullName && e.prNumber === pr.number,
        );

        if (!alreadyExists) {
          await ctx.db.insert("taskRunPullRequests", {
            taskRunId: run._id,
            teamId: run.teamId,
            repoFullName: pr.repoFullName,
            prNumber: pr.number,
            createdAt: Date.now(),
          });
          totalInserted++;
        }
      }
      totalProcessed++;
    }

    console.log(
      `[backfillTaskRunPullRequests] Batch complete. Processed ${totalProcessed} taskRuns, inserted ${totalInserted} entries. isDone=${results.isDone}`,
    );

    // Schedule next batch if there's more data
    if (!results.isDone) {
      await ctx.scheduler.runAfter(
        0,
        internal.migrations.backfillTaskRunPullRequestsContinue,
        { cursor: results.continueCursor },
      );
    }

    return { totalProcessed, totalInserted, isDone: results.isDone };
  },
});

/**
 * Continue backfilling from a cursor. Called by backfillTaskRunPullRequests.
 */
export const backfillTaskRunPullRequestsContinue = internalMutation({
  args: {
    cursor: v.string(),
  },
  handler: async (ctx, { cursor }) => {
    let totalProcessed = 0;
    let totalInserted = 0;
    const batchSize = 50;

    const results = await ctx.db
      .query("taskRuns")
      .paginate({ cursor, numItems: batchSize });

    for (const run of results.page) {
      if (!run.pullRequests || run.pullRequests.length === 0) {
        continue;
      }

      for (const pr of run.pullRequests) {
        if (pr.number === undefined) {
          continue;
        }

        const existingEntries = await ctx.db
          .query("taskRunPullRequests")
          .withIndex("by_task_run", (q) => q.eq("taskRunId", run._id))
          .collect();

        const alreadyExists = existingEntries.some(
          (e) =>
            e.repoFullName === pr.repoFullName && e.prNumber === pr.number,
        );

        if (!alreadyExists) {
          await ctx.db.insert("taskRunPullRequests", {
            taskRunId: run._id,
            teamId: run.teamId,
            repoFullName: pr.repoFullName,
            prNumber: pr.number,
            createdAt: Date.now(),
          });
          totalInserted++;
        }
      }
      totalProcessed++;
    }

    console.log(
      `[backfillTaskRunPullRequests] Batch complete. Processed ${totalProcessed} taskRuns, inserted ${totalInserted} entries. isDone=${results.isDone}`,
    );

    // Schedule next batch if there's more data
    if (!results.isDone) {
      await ctx.scheduler.runAfter(
        0,
        internal.migrations.backfillTaskRunPullRequestsContinue,
        { cursor: results.continueCursor },
      );
    }

    return { totalProcessed, totalInserted, isDone: results.isDone };
  },
});
