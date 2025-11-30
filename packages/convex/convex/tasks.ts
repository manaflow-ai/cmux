import { v } from "convex/values";
import { resolveTeamIdLoose } from "../_shared/team";
import { api } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { internalMutation, internalQuery } from "./_generated/server";
import { authMutation, authQuery, taskIdWithFake } from "./users/utils";

export const get = authQuery({
  args: {
    teamSlugOrId: v.string(),
    projectFullName: v.optional(v.string()),
    archived: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    let q = ctx.db
      .query("tasks")
      .withIndex("by_team_user", (idx) =>
        idx.eq("teamId", teamId).eq("userId", userId),
      );

    if (args.archived === true) {
      q = q.filter((qq) => qq.eq(qq.field("isArchived"), true));
    } else {
      q = q.filter((qq) => qq.neq(qq.field("isArchived"), true));
    }

    if (args.projectFullName) {
      q = q.filter((qq) =>
        qq.eq(qq.field("projectFullName"), args.projectFullName),
      );
    }

    // Note: order by createdAt desc, fallback to insertion order if not present
    const results = await q.collect();
    return results.sort((a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0));
  },
});

export const getPinned = authQuery({
  args: {
    teamSlugOrId: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    // Get pinned tasks
    const pinnedTasks = await ctx.db
      .query("tasks")
      .withIndex("by_pinned", (idx) =>
        idx.eq("pinned", true).eq("teamId", teamId).eq("userId", userId),
      )
      .filter((q) => q.neq(q.field("isArchived"), true))
      .collect();

    return pinnedTasks.sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0));
  },
});

export const getTasksWithTaskRuns = authQuery({
  args: {
    teamSlugOrId: v.string(),
    projectFullName: v.optional(v.string()),
    archived: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    let q = ctx.db
      .query("tasks")
      .withIndex("by_team_user", (idx) =>
        idx.eq("teamId", teamId).eq("userId", userId),
      );

    if (args.archived === true) {
      q = q.filter((qq) => qq.eq(qq.field("isArchived"), true));
    } else {
      q = q.filter((qq) => qq.neq(qq.field("isArchived"), true));
    }

    if (args.projectFullName) {
      q = q.filter((qq) =>
        qq.eq(qq.field("projectFullName"), args.projectFullName),
      );
    }

    const tasks = await q.collect();
    const sortedTasks = tasks.sort(
      (a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0),
    );

    const tasksWithRuns = await Promise.all(
      sortedTasks.map(async (task) => {
        const crownedRun = await ctx.db
          .query("taskRuns")
          .withIndex("by_task", (query) => query.eq("taskId", task._id))
          .filter((query) => query.eq(query.field("isCrowned"), true))
          .filter((query) => query.neq(query.field("isArchived"), true))
          .first();

        let selectedTaskRun = crownedRun ?? null;

        if (!selectedTaskRun) {
          const [latestRun] = await ctx.db
            .query("taskRuns")
            .withIndex("by_task", (query) => query.eq("taskId", task._id))
            .filter((query) => query.neq(query.field("isArchived"), true))
            .order("desc")
            .take(1);
          selectedTaskRun = latestRun ?? null;
        }

        return {
          ...task,
          selectedTaskRun,
        };
      }),
    );

    return tasksWithRuns;
  },
});

export const create = authMutation({
  args: {
    teamSlugOrId: v.string(),
    text: v.string(),
    description: v.optional(v.string()),
    projectFullName: v.optional(v.string()),
    baseBranch: v.optional(v.string()),
    worktreePath: v.optional(v.string()),
    images: v.optional(
      v.array(
        v.object({
          storageId: v.id("_storage"),
          fileName: v.optional(v.string()),
          altText: v.string(),
        }),
      ),
    ),
    environmentId: v.optional(v.id("environments")),
    isCloudWorkspace: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    if (args.environmentId) {
      const environment = await ctx.db.get(args.environmentId);
      if (!environment || environment.teamId !== teamId) {
        throw new Error("Environment not found");
      }
    }
    const now = Date.now();
    const taskId = await ctx.db.insert("tasks", {
      text: args.text,
      description: args.description,
      projectFullName: args.projectFullName,
      baseBranch: args.baseBranch,
      worktreePath: args.worktreePath,
      isCompleted: false,
      createdAt: now,
      updatedAt: now,
      images: args.images,
      userId,
      teamId,
      environmentId: args.environmentId,
      isCloudWorkspace: args.isCloudWorkspace,
    });

    return taskId;
  },
});

export const remove = authMutation({
  args: { teamSlugOrId: v.string(), id: v.id("tasks") },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.id);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.delete(args.id);
  },
});

export const toggle = authMutation({
  args: { teamSlugOrId: v.string(), id: v.id("tasks") },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (task === null || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(args.id, { isCompleted: !task.isCompleted });
  },
});

export const setCompleted = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("tasks"),
    isCompleted: v.boolean(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (task === null || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found");
    }
    await ctx.db.patch(args.id, {
      isCompleted: args.isCompleted,
      updatedAt: Date.now(),
    });
  },
});

export const update = authMutation({
  args: { teamSlugOrId: v.string(), id: v.id("tasks"), text: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (task === null || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(args.id, { text: args.text, updatedAt: Date.now() });
  },
});

export const updateWorktreePath = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("tasks"),
    worktreePath: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (!task || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(args.id, {
      worktreePath: args.worktreePath,
      updatedAt: Date.now(),
    });
  },
});

export const getById = authQuery({
  args: { teamSlugOrId: v.string(), id: taskIdWithFake },
  handler: async (ctx, args) => {
    // Handle fake IDs by returning null
    if (typeof args.id === "string" && args.id.startsWith("fake-")) {
      return null;
    }

    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id as Id<"tasks">);
    if (!task || task.teamId !== teamId || task.userId !== userId) return null;

    if (task.images && task.images.length > 0) {
      const imagesWithUrls = await Promise.all(
        task.images.map(async (image) => {
          const url = await ctx.storage.getUrl(image.storageId);
          return {
            ...image,
            url,
          };
        }),
      );
      return {
        ...task,
        images: imagesWithUrls,
      };
    }

    return task;
  },
});

export const getVersions = authQuery({
  args: { teamSlugOrId: v.string(), taskId: v.id("tasks") },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    return await ctx.db
      .query("taskVersions")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .filter((q) => q.eq(q.field("teamId"), teamId))
      .filter((q) => q.eq(q.field("userId"), userId))
      .collect();
  },
});

export const archive = authMutation({
  args: { teamSlugOrId: v.string(), id: v.id("tasks") },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (task === null || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(args.id, { isArchived: true, updatedAt: Date.now() });
  },
});

export const unarchive = authMutation({
  args: { teamSlugOrId: v.string(), id: v.id("tasks") },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (task === null || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(args.id, { isArchived: false, updatedAt: Date.now() });
  },
});

export const pin = authMutation({
  args: { teamSlugOrId: v.string(), id: v.id("tasks") },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (task === null || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(args.id, { pinned: true, updatedAt: Date.now() });
  },
});

export const unpin = authMutation({
  args: { teamSlugOrId: v.string(), id: v.id("tasks") },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (task === null || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(args.id, { pinned: false, updatedAt: Date.now() });
  },
});

export const updateCrownError = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("tasks"),
    crownEvaluationStatus: v.optional(
      v.union(
        v.literal("pending"),
        v.literal("in_progress"),
        v.literal("succeeded"),
        v.literal("error"),
      ),
    ),
    crownEvaluationError: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const { id, teamSlugOrId, ...updates } = args;
    const teamId = await resolveTeamIdLoose(ctx, teamSlugOrId);
    const task = await ctx.db.get(id);
    if (!task || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(id, {
      ...updates,
      updatedAt: Date.now(),
    });
  },
});

export const setCrownEvaluationStatusInternal = internalMutation({
  args: {
    taskId: v.id("tasks"),
    teamId: v.string(),
    userId: v.string(),
    status: v.union(
      v.literal("pending"),
      v.literal("in_progress"),
      v.literal("succeeded"),
      v.literal("error"),
    ),
    errorMessage: v.optional(v.string()),
    clearError: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.taskId);
    if (!task || task.teamId !== args.teamId || task.userId !== args.userId) {
      throw new Error("Task not found or unauthorized");
    }

    const patch: Record<string, unknown> = {
      crownEvaluationStatus: args.status,
      updatedAt: Date.now(),
    };

    if (args.clearError) {
      patch.crownEvaluationError = undefined;
    } else if (Object.prototype.hasOwnProperty.call(args, "errorMessage")) {
      patch.crownEvaluationError = args.errorMessage;
    }

    await ctx.db.patch(args.taskId, patch);
  },
});

// Try to atomically begin a crown evaluation; returns true if we acquired the lock
export const tryBeginCrownEvaluation = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("tasks"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (!task || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    if (task.crownEvaluationStatus === "in_progress") {
      return false;
    }
    await ctx.db.patch(args.id, {
      crownEvaluationStatus: "in_progress",
      crownEvaluationError: undefined,
      updatedAt: Date.now(),
    });
    return true;
  },
});

// Set or update the generated pull request description for a task
export const setPullRequestDescription = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("tasks"),
    pullRequestDescription: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const { id, teamSlugOrId, pullRequestDescription } = args;
    const teamId = await resolveTeamIdLoose(ctx, teamSlugOrId);
    const task = await ctx.db.get(id);
    if (!task || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(id, {
      pullRequestDescription,
      updatedAt: Date.now(),
    });
  },
});

// Set or update the generated pull request title for a task
export const setPullRequestTitle = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("tasks"),
    pullRequestTitle: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const { id, teamSlugOrId, pullRequestTitle } = args;
    const teamId = await resolveTeamIdLoose(ctx, teamSlugOrId);
    const task = await ctx.db.get(id);
    if (!task || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    await ctx.db.patch(id, {
      pullRequestTitle,
      updatedAt: Date.now(),
    });
  },
});

export const createVersion = authMutation({
  args: {
    teamSlugOrId: v.string(),
    taskId: v.id("tasks"),
    diff: v.string(),
    summary: v.string(),
    files: v.array(
      v.object({
        path: v.string(),
        changes: v.string(),
      }),
    ),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const existingVersions = await ctx.db
      .query("taskVersions")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .filter((q) => q.eq(q.field("teamId"), teamId))
      .filter((q) => q.eq(q.field("userId"), userId))
      .collect();

    const version = existingVersions.length + 1;

    const versionId = await ctx.db.insert("taskVersions", {
      taskId: args.taskId,
      version,
      diff: args.diff,
      summary: args.summary,
      files: args.files,
      createdAt: Date.now(),
      userId,
      teamId,
    });

    await ctx.db.patch(args.taskId, { updatedAt: Date.now() });

    return versionId;
  },
});

// Check if all runs for a task are completed and trigger crown evaluation
export const getTasksWithPendingCrownEvaluation = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    // Only get tasks that are pending, not already in progress
    const tasks = await ctx.db
      .query("tasks")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .filter((q) => q.eq(q.field("crownEvaluationStatus"), "pending"))
      .collect();

    // Double-check that no evaluation exists for these tasks
    const tasksToEvaluate = [];
    for (const task of tasks) {
      const existingEvaluation = await ctx.db
        .query("crownEvaluations")
        .withIndex("by_task", (q) => q.eq("taskId", task._id))
        .filter((q) => q.eq(q.field("teamId"), teamId))
        .filter((q) => q.eq(q.field("userId"), userId))
        .first();

      if (!existingEvaluation) {
        tasksToEvaluate.push(task);
      }
    }

    return tasksToEvaluate;
  },
});

export const updateMergeStatus = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("tasks"),
    mergeStatus: v.union(
      v.literal("none"),
      v.literal("pr_draft"),
      v.literal("pr_open"),
      v.literal("pr_approved"),
      v.literal("pr_changes_requested"),
      v.literal("pr_merged"),
      v.literal("pr_closed"),
    ),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.id);
    if (task === null || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found");
    }
    await ctx.db.patch(args.id, {
      mergeStatus: args.mergeStatus,
      updatedAt: Date.now(),
    });
  },
});

export const recordScreenshotResult = internalMutation({
  args: {
    taskId: v.id("tasks"),
    runId: v.id("taskRuns"),
    status: v.union(
      v.literal("completed"),
      v.literal("failed"),
      v.literal("skipped"),
    ),
    hasUiChanges: v.optional(v.boolean()),
    screenshots: v.optional(
      v.array(
        v.object({
          storageId: v.id("_storage"),
          mimeType: v.string(),
          fileName: v.optional(v.string()),
          commitSha: v.string(),
          description: v.optional(v.string()),
        }),
      ),
    ),
    error: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.taskId);
    if (!task) {
      throw new Error("Task not found");
    }

    const run = await ctx.db.get(args.runId);
    if (!run || run.taskId !== args.taskId) {
      throw new Error("Task run not found for task");
    }

    const now = Date.now();
    const screenshots = args.screenshots ?? [];

    const screenshotSetId = await ctx.db.insert("taskRunScreenshotSets", {
      taskId: args.taskId,
      runId: args.runId,
      status: args.status,
      hasUiChanges: args.hasUiChanges ?? undefined,
      commitSha: screenshots[0]?.commitSha,
      capturedAt: now,
      error: args.error ?? undefined,
      images: screenshots.map((screenshot) => ({
        storageId: screenshot.storageId,
        mimeType: screenshot.mimeType,
        fileName: screenshot.fileName,
        commitSha: screenshot.commitSha,
        description: screenshot.description,
      })),
      createdAt: now,
      updatedAt: now,
    });

    const patch: Record<string, unknown> = {
      screenshotStatus: args.status,
      screenshotRunId: args.runId,
      screenshotRequestedAt: now,
      updatedAt: now,
      latestScreenshotSetId:
        args.status === "completed" && screenshots.length > 0
          ? screenshotSetId
          : undefined,
    };

    if (args.status === "completed" && screenshots.length > 0) {
      patch.screenshotStorageId = screenshots[0].storageId;
      patch.screenshotMimeType = screenshots[0].mimeType;
      patch.screenshotFileName = screenshots[0].fileName;
      patch.screenshotCommitSha = screenshots[0].commitSha;
      patch.screenshotCompletedAt = now;
      patch.screenshotError = undefined;
    } else {
      patch.screenshotStorageId = undefined;
      patch.screenshotMimeType = undefined;
      patch.screenshotFileName = undefined;
      patch.screenshotCommitSha = undefined;
      patch.screenshotCompletedAt = undefined;
      patch.screenshotError = args.error ?? undefined;
    }

    if (args.status === "failed" || args.status === "skipped") {
      patch.screenshotError = args.error ?? patch.screenshotError;
    }

    await ctx.db.patch(args.taskId, patch);

    return screenshotSetId;
  },
});

export const checkAndEvaluateCrown = authMutation({
  args: {
    teamSlugOrId: v.string(),
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args): Promise<Id<"taskRuns"> | "pending" | null> => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    // Get all runs for this task
    const taskRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .filter((q) => q.eq(q.field("teamId"), teamId))
      .filter((q) => q.eq(q.field("userId"), userId))
      .collect();

    console.log(`[CheckCrown] Task ${args.taskId} has ${taskRuns.length} runs`);
    console.log(
      `[CheckCrown] Run statuses:`,
      taskRuns.map((r) => ({
        id: r._id,
        status: r.status,
        isCrowned: r.isCrowned,
      })),
    );

    // Check if all runs are completed or failed
    const allCompleted = taskRuns.every(
      (run) => run.status === "completed" || run.status === "failed",
    );

    if (!allCompleted) {
      console.log(`[CheckCrown] Not all runs completed`);
      return null;
    }

    // Special handling for single agent scenario
    if (taskRuns.length === 1) {
      console.log(`[CheckCrown] Single agent scenario - marking task complete`);

      // Mark the task as completed
      await ctx.db.patch(args.taskId, {
        isCompleted: true,
        updatedAt: Date.now(),
      });

      // If the single run was successful, return it as the "winner" for potential auto-PR
      const singleRun = taskRuns[0];
      if (singleRun.status === "completed") {
        console.log(
          `[CheckCrown] Single agent completed successfully: ${singleRun._id}`,
        );
        return singleRun._id;
      }

      return null;
    }

    // For multiple runs, require at least 2 to perform crown evaluation
    if (taskRuns.length < 2) {
      console.log(`[CheckCrown] Not enough runs (${taskRuns.length} < 2)`);
      return null;
    }

    // Check if we've already evaluated crown for this task
    const existingEvaluation = await ctx.db
      .query("crownEvaluations")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .filter((q) => q.eq(q.field("teamId"), teamId))
      .filter((q) => q.eq(q.field("userId"), userId))
      .first();

    if (existingEvaluation) {
      console.log(
        `[CheckCrown] Crown already evaluated for task ${args.taskId}, winner: ${existingEvaluation.winnerRunId}`,
      );
      return existingEvaluation.winnerRunId;
    }

    // Check if crown evaluation is already pending or in progress
    const task = await ctx.db.get(args.taskId);
    if (
      task?.crownEvaluationStatus === "pending" ||
      task?.crownEvaluationStatus === "in_progress"
    ) {
      console.log(
        `[CheckCrown] Crown evaluation already ${task.crownEvaluationStatus} for task ${args.taskId}`,
      );
      return "pending";
    }

    console.log(
      `[CheckCrown] No existing evaluation, proceeding with crown evaluation`,
    );

    // Only evaluate if we have at least 2 completed runs
    const completedRuns = taskRuns.filter((run) => run.status === "completed");
    if (completedRuns.length < 2) {
      console.log(
        `[CheckCrown] Not enough completed runs (${completedRuns.length} < 2)`,
      );
      return null;
    }

    // Trigger crown evaluation with error handling
    let winnerId = null;
    try {
      console.log(
        `[CheckCrown] Starting crown evaluation for task ${args.taskId}`,
      );
      winnerId = await ctx.runMutation(api.crown.evaluateAndCrownWinner, {
        teamSlugOrId: args.teamSlugOrId,
        taskId: args.taskId,
      });
      console.log(
        `[CheckCrown] Crown evaluation completed, winner: ${winnerId}`,
      );
    } catch (error) {
      console.error(`[CheckCrown] Crown evaluation failed:`, error);
      // Store the error message on the task
      const errorMessage =
        error instanceof Error ? error.message : String(error);
      await ctx.db.patch(args.taskId, {
        crownEvaluationStatus: "error",
        crownEvaluationError: errorMessage,
        updatedAt: Date.now(),
      });
      // Continue to mark task as completed even if crown evaluation fails
    }

    // Mark the task as completed since all runs are done
    await ctx.db.patch(args.taskId, {
      isCompleted: true,
      updatedAt: Date.now(),
    });
    console.log(`[CheckCrown] Marked task ${args.taskId} as completed`);

    return winnerId;
  },
});

export const getByIdInternal = internalQuery({
  args: { id: v.id("tasks") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.id);
  },
});

export const createForPreview = internalMutation({
  args: {
    teamId: v.string(),
    userId: v.string(),
    previewRunId: v.id("previewRuns"),
    repoFullName: v.string(),
    prNumber: v.number(),
    prUrl: v.string(),
    headSha: v.string(),
    baseBranch: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const taskId = await ctx.db.insert("tasks", {
      text: `Preview screenshots for PR #${args.prNumber}`,
      description: `Capture UI screenshots for ${args.prUrl}`,
      projectFullName: args.repoFullName,
      baseBranch: args.baseBranch,
      worktreePath: undefined,
      isCompleted: false,
      createdAt: now,
      updatedAt: now,
      images: undefined,
      userId: args.userId,
      teamId: args.teamId,
      environmentId: undefined,
      isCloudWorkspace: undefined,
    });
    return taskId;
  },
});
