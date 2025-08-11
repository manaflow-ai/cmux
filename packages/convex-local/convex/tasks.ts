import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { api } from "./_generated/api";
import type { Id } from "./_generated/dataModel";

export const get = query({
  args: {
    projectFullName: v.optional(v.string()),
    archived: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    let query = ctx.db.query("tasks");

    // Default to active (non-archived) when not specified
    if (args.archived === true) {
      query = query.filter((q) => q.eq(q.field("isArchived"), true));
    } else {
      query = query.filter((q) => q.neq(q.field("isArchived"), true));
    }

    if (args.projectFullName) {
      query = query.filter((q) =>
        q.eq(q.field("projectFullName"), args.projectFullName)
      );
    }

    return await query.order("desc").collect();
  },
});

export const create = mutation({
  args: {
    text: v.string(),
    description: v.optional(v.string()),
    projectFullName: v.optional(v.string()),
    branch: v.optional(v.string()),
    worktreePath: v.optional(v.string()),
    images: v.optional(v.array(v.object({
      storageId: v.id("_storage"),
      fileName: v.optional(v.string()),
      altText: v.string(),
    }))),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const taskId = await ctx.db.insert("tasks", {
      text: args.text,
      description: args.description,
      projectFullName: args.projectFullName,
      branch: args.branch,
      worktreePath: args.worktreePath,
      isCompleted: false,
      createdAt: now,
      updatedAt: now,
      images: args.images,
    });

    return taskId;
  },
});

export const remove = mutation({
  args: { id: v.id("tasks") },
  handler: async (ctx, args) => {
    await ctx.db.delete(args.id);
  },
});

export const toggle = mutation({
  args: { id: v.id("tasks") },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.id);
    if (task === null) {
      throw new Error("Task not found");
    }
    await ctx.db.patch(args.id, { isCompleted: !task.isCompleted });
  },
});

export const setCompleted = mutation({
  args: {
    id: v.id("tasks"),
    isCompleted: v.boolean(),
  },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.id);
    if (task === null) {
      throw new Error("Task not found");
    }
    await ctx.db.patch(args.id, {
      isCompleted: args.isCompleted,
      updatedAt: Date.now(),
    });
  },
});

export const update = mutation({
  args: { id: v.id("tasks"), text: v.string() },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.id);
    if (task === null) {
      throw new Error("Task not found");
    }
    await ctx.db.patch(args.id, { text: args.text, updatedAt: Date.now() });
  },
});

export const getById = query({
  args: { id: v.id("tasks") },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.id);
    if (!task) return null;
    
    // If task has images, get their URLs
    if (task.images && task.images.length > 0) {
      const imagesWithUrls = await Promise.all(
        task.images.map(async (image) => {
          const url = await ctx.storage.getUrl(image.storageId);
          return {
            ...image,
            url,
          };
        })
      );
      return {
        ...task,
        images: imagesWithUrls,
      };
    }
    
    return task;
  },
});

export const getVersions = query({
  args: { taskId: v.id("tasks") },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("taskVersions")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .collect();
  },
});

export const archive = mutation({
  args: { id: v.id("tasks") },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.id);
    if (task === null) {
      throw new Error("Task not found");
    }
    await ctx.db.patch(args.id, { isArchived: true, updatedAt: Date.now() });
  },
});

export const unarchive = mutation({
  args: { id: v.id("tasks") },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.id);
    if (task === null) {
      throw new Error("Task not found");
    }
    await ctx.db.patch(args.id, { isArchived: false, updatedAt: Date.now() });
  },
});

export const updateCrownError = mutation({
  args: {
    id: v.id("tasks"),
    crownEvaluationError: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const { id, ...updates } = args;
    await ctx.db.patch(id, {
      ...updates,
      updatedAt: Date.now(),
    });
  },
});

export const createVersion = mutation({
  args: {
    taskId: v.id("tasks"),
    diff: v.string(),
    summary: v.string(),
    files: v.array(
      v.object({
        path: v.string(),
        changes: v.string(),
      })
    ),
  },
  handler: async (ctx, args) => {
    const existingVersions = await ctx.db
      .query("taskVersions")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .collect();

    const version = existingVersions.length + 1;

    const versionId = await ctx.db.insert("taskVersions", {
      taskId: args.taskId,
      version,
      diff: args.diff,
      summary: args.summary,
      files: args.files,
      createdAt: Date.now(),
    });

    await ctx.db.patch(args.taskId, { updatedAt: Date.now() });

    return versionId;
  },
});

// Check if all runs for a task are completed and trigger crown evaluation
export const getTasksWithPendingCrownEvaluation = query({
  args: {},
  handler: async (ctx) => {
    // Only get tasks that are pending, not already in progress
    const tasks = await ctx.db
      .query("tasks")
      .filter((q) => q.eq(q.field("crownEvaluationError"), "pending_evaluation"))
      .collect();
    
    // Double-check that no evaluation exists for these tasks
    const tasksToEvaluate = [];
    for (const task of tasks) {
      const existingEvaluation = await ctx.db
        .query("crownEvaluations")
        .withIndex("by_task", (q) => q.eq("taskId", task._id))
        .first();
      
      if (!existingEvaluation) {
        tasksToEvaluate.push(task);
      }
    }
    
    return tasksToEvaluate;
  },
});

export const checkAndEvaluateCrown = mutation({
  args: {
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args): Promise<Id<"taskRuns"> | "pending" | null> => {
    // Get all runs for this task
    const taskRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .collect();

    console.log(`[CheckCrown] Task ${args.taskId} has ${taskRuns.length} runs`);
    console.log(`[CheckCrown] Run statuses:`, taskRuns.map(r => ({ id: r._id, status: r.status, isCrowned: r.isCrowned })));

    // Check if we have multiple runs
    if (taskRuns.length < 2) {
      console.log(`[CheckCrown] Not enough runs (${taskRuns.length} < 2)`);
      return null;
    }

    // Check if all runs are completed or failed
    const allCompleted = taskRuns.every(
      (run) => run.status === "completed" || run.status === "failed"
    );

    if (!allCompleted) {
      console.log(`[CheckCrown] Not all runs completed`);
      return null;
    }

    // Check if we've already evaluated crown for this task
    const existingEvaluation = await ctx.db
      .query("crownEvaluations")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .first();

    if (existingEvaluation) {
      console.log(`[CheckCrown] Crown already evaluated for task ${args.taskId}, winner: ${existingEvaluation.winnerRunId}`);
      return existingEvaluation.winnerRunId;
    }
    
    // Check if crown evaluation is already pending or in progress
    const task = await ctx.db.get(args.taskId);
    if (task?.crownEvaluationError === "pending_evaluation" || 
        task?.crownEvaluationError === "in_progress") {
      console.log(`[CheckCrown] Crown evaluation already ${task.crownEvaluationError} for task ${args.taskId}`);
      return "pending";
    }
    
    console.log(`[CheckCrown] No existing evaluation, proceeding with crown evaluation`);
    
    // Only evaluate if we have at least 2 completed runs
    const completedRuns = taskRuns.filter(run => run.status === "completed");
    if (completedRuns.length < 2) {
      console.log(`[CheckCrown] Not enough completed runs (${completedRuns.length} < 2)`);
      return null;
    }

    // Trigger crown evaluation with error handling
    let winnerId = null;
    try {
      console.log(`[CheckCrown] Starting crown evaluation for task ${args.taskId}`);
      winnerId = await ctx.runMutation(api.crown.evaluateAndCrownWinner, {
        taskId: args.taskId,
      });
      console.log(`[CheckCrown] Crown evaluation completed, winner: ${winnerId}`);
    } catch (error) {
      console.error(`[CheckCrown] Crown evaluation failed:`, error);
      // Store the error message on the task
      const errorMessage = error instanceof Error ? error.message : String(error);
      await ctx.db.patch(args.taskId, {
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
