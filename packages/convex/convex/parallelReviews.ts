import { v } from "convex/values";
import { getTeamId } from "../_shared/team";
import type { Doc, Id } from "./_generated/dataModel";
import {
  internalMutation,
  internalQuery,
  type MutationCtx,
} from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";

// Reviewer agents available for parallel reviews
export const REVIEWER_AGENTS = ["claude", "codex", "gemini"] as const;
export type ReviewerAgent = (typeof REVIEWER_AGENTS)[number];

type ParallelReviewDoc = Doc<"parallelReviews">;
type ParallelReviewSetDoc = Doc<"parallelReviewSets">;

// Serialization helpers
function serializeReview(review: ParallelReviewDoc) {
  return {
    id: review._id,
    taskId: review.taskId,
    taskRunId: review.taskRunId,
    teamId: review.teamId,
    reviewerAgent: review.reviewerAgent,
    status: review.status,
    reviewOutput: review.reviewOutput ?? null,
    score: review.score ?? null,
    strengths: review.strengths ?? [],
    weaknesses: review.weaknesses ?? [],
    suggestions: review.suggestions ?? [],
    errorCode: review.errorCode ?? null,
    errorDetail: review.errorDetail ?? null,
    sandboxInstanceId: review.sandboxInstanceId ?? null,
    startedAt: review.startedAt ?? null,
    completedAt: review.completedAt ?? null,
    createdAt: review.createdAt,
    updatedAt: review.updatedAt,
  };
}

function serializeReviewSet(set: ParallelReviewSetDoc) {
  return {
    id: set._id,
    taskId: set.taskId,
    teamId: set.teamId,
    status: set.status,
    taskRunIds: set.taskRunIds,
    aggregatedSummary: set.aggregatedSummary ?? null,
    startedAt: set.startedAt ?? null,
    completedAt: set.completedAt ?? null,
    createdAt: set.createdAt,
    updatedAt: set.updatedAt,
  };
}

// ============================================================================
// Internal mutations (called by HTTP endpoints and worker callbacks)
// ============================================================================

/**
 * Create a parallel review set for a task.
 * This creates the parent reviewSet and individual review jobs for each run x agent.
 */
export const createReviewSet = internalMutation({
  args: {
    taskId: v.id("tasks"),
    taskRunIds: v.array(v.id("taskRuns")),
    teamId: v.string(),
    userId: v.string(),
    reviewerAgents: v.optional(v.array(v.string())),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const agents = (args.reviewerAgents as ReviewerAgent[]) ?? REVIEWER_AGENTS;

    // Check if a review set already exists for this task
    const existingSet = await ctx.db
      .query("parallelReviewSets")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .first();

    if (existingSet) {
      console.log(
        "[parallelReviews] Review set already exists for task",
        args.taskId
      );
      return {
        reviewSetId: existingSet._id,
        reviewIds: [],
        alreadyExists: true,
      };
    }

    // Create the review set
    const reviewSetId = await ctx.db.insert("parallelReviewSets", {
      taskId: args.taskId,
      teamId: args.teamId,
      userId: args.userId,
      status: "pending",
      taskRunIds: args.taskRunIds,
      createdAt: now,
      updatedAt: now,
    });

    // Create individual review jobs for each run x agent combination
    const reviewIds: Id<"parallelReviews">[] = [];

    for (const taskRunId of args.taskRunIds) {
      for (const agent of agents) {
        // Check if review already exists for this run+agent
        const existingReview = await ctx.db
          .query("parallelReviews")
          .withIndex("by_task_run_agent", (q) =>
            q.eq("taskRunId", taskRunId).eq("reviewerAgent", agent)
          )
          .first();

        if (existingReview) {
          reviewIds.push(existingReview._id);
          continue;
        }

        const reviewId = await ctx.db.insert("parallelReviews", {
          taskId: args.taskId,
          taskRunId,
          teamId: args.teamId,
          userId: args.userId,
          reviewerAgent: agent,
          status: "pending",
          createdAt: now,
          updatedAt: now,
        });
        reviewIds.push(reviewId);
      }
    }

    console.log(
      `[parallelReviews] Created review set ${reviewSetId} with ${reviewIds.length} reviews for task ${args.taskId}`
    );

    return {
      reviewSetId,
      reviewIds,
      alreadyExists: false,
    };
  },
});

/**
 * Mark a review as running (when agent sandbox starts)
 */
export const markReviewRunning = internalMutation({
  args: {
    reviewId: v.id("parallelReviews"),
    sandboxInstanceId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const review = await ctx.db.get(args.reviewId);
    if (!review) {
      throw new Error("Review not found");
    }

    if (review.status !== "pending") {
      console.log(
        `[parallelReviews] Review ${args.reviewId} already ${review.status}, skipping`
      );
      return serializeReview(review);
    }

    const now = Date.now();
    await ctx.db.patch(args.reviewId, {
      status: "running",
      startedAt: now,
      updatedAt: now,
      ...(args.sandboxInstanceId
        ? { sandboxInstanceId: args.sandboxInstanceId }
        : {}),
    });

    // Update review set status if needed
    await updateReviewSetStatus(ctx, review.taskId);

    const updated = await ctx.db.get(args.reviewId);
    return serializeReview(updated!);
  },
});

/**
 * Complete a review with results from the agent
 */
export const completeReview = internalMutation({
  args: {
    reviewId: v.id("parallelReviews"),
    reviewOutput: v.string(),
    score: v.optional(v.number()),
    strengths: v.optional(v.array(v.string())),
    weaknesses: v.optional(v.array(v.string())),
    suggestions: v.optional(v.array(v.string())),
    sandboxInstanceId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const review = await ctx.db.get(args.reviewId);
    if (!review) {
      throw new Error("Review not found");
    }

    const now = Date.now();
    await ctx.db.patch(args.reviewId, {
      status: "completed",
      reviewOutput: args.reviewOutput,
      score: args.score,
      strengths: args.strengths,
      weaknesses: args.weaknesses,
      suggestions: args.suggestions,
      completedAt: now,
      updatedAt: now,
      ...(args.sandboxInstanceId
        ? { sandboxInstanceId: args.sandboxInstanceId }
        : {}),
    });

    // Update review set status
    await updateReviewSetStatus(ctx, review.taskId);

    const updated = await ctx.db.get(args.reviewId);
    return serializeReview(updated!);
  },
});

/**
 * Fail a review
 */
export const failReview = internalMutation({
  args: {
    reviewId: v.id("parallelReviews"),
    errorCode: v.string(),
    errorDetail: v.optional(v.string()),
    sandboxInstanceId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const review = await ctx.db.get(args.reviewId);
    if (!review) {
      throw new Error("Review not found");
    }

    const now = Date.now();
    await ctx.db.patch(args.reviewId, {
      status: "failed",
      errorCode: args.errorCode,
      errorDetail: args.errorDetail,
      completedAt: now,
      updatedAt: now,
      ...(args.sandboxInstanceId
        ? { sandboxInstanceId: args.sandboxInstanceId }
        : {}),
    });

    // Update review set status
    await updateReviewSetStatus(ctx, review.taskId);

    const updated = await ctx.db.get(args.reviewId);
    return serializeReview(updated!);
  },
});

/**
 * Set the aggregated summary on the review set after all reviews complete
 */
export const setAggregatedSummary = internalMutation({
  args: {
    reviewSetId: v.id("parallelReviewSets"),
    aggregatedSummary: v.string(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    await ctx.db.patch(args.reviewSetId, {
      aggregatedSummary: args.aggregatedSummary,
      updatedAt: now,
    });
  },
});

// Helper to update review set status based on individual reviews
async function updateReviewSetStatus(
  ctx: MutationCtx,
  taskId: Id<"tasks">
): Promise<void> {
  const reviewSet = await ctx.db
    .query("parallelReviewSets")
    .withIndex("by_task", (q) => q.eq("taskId", taskId))
    .first();

  if (!reviewSet) {
    return;
  }

  // Get all reviews for this task
  const reviews = await ctx.db
    .query("parallelReviews")
    .withIndex("by_task", (q) => q.eq("taskId", taskId))
    .collect();

  const now = Date.now();
  const statuses = reviews.map((r) => r.status);

  let newStatus: "pending" | "in_progress" | "completed" | "failed" =
    reviewSet.status;

  if (statuses.every((s) => s === "completed" || s === "failed")) {
    // All done
    newStatus = statuses.some((s) => s === "completed") ? "completed" : "failed";
  } else if (statuses.some((s) => s === "running" || s === "completed")) {
    // Some in progress
    newStatus = "in_progress";
  } else {
    newStatus = "pending";
  }

  if (newStatus !== reviewSet.status) {
    await ctx.db.patch(reviewSet._id, {
      status: newStatus,
      updatedAt: now,
      ...(newStatus === "completed" || newStatus === "failed"
        ? { completedAt: now }
        : {}),
      ...(newStatus === "in_progress" && !reviewSet.startedAt
        ? { startedAt: now }
        : {}),
    });

    console.log(
      `[parallelReviews] Updated review set ${reviewSet._id} status to ${newStatus}`
    );
  }
}

// ============================================================================
// Internal queries
// ============================================================================

export const getReviewSetByTaskInternal = internalQuery({
  args: {
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args) => {
    const set = await ctx.db
      .query("parallelReviewSets")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .first();
    return set ? serializeReviewSet(set) : null;
  },
});

export const listReviewsByTaskInternal = internalQuery({
  args: {
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args) => {
    const reviews = await ctx.db
      .query("parallelReviews")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .collect();
    return reviews.map(serializeReview);
  },
});

export const listReviewsByTaskRunInternal = internalQuery({
  args: {
    taskRunId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const reviews = await ctx.db
      .query("parallelReviews")
      .withIndex("by_task_run", (q) => q.eq("taskRunId", args.taskRunId))
      .collect();
    return reviews.map(serializeReview);
  },
});

export const getReviewByIdInternal = internalQuery({
  args: {
    reviewId: v.id("parallelReviews"),
  },
  handler: async (ctx, args) => {
    const review = await ctx.db.get(args.reviewId);
    return review ? serializeReview(review) : null;
  },
});

export const getPendingReviewsInternal = internalQuery({
  args: {
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args) => {
    const reviews = await ctx.db
      .query("parallelReviews")
      .withIndex("by_task_status", (q) =>
        q.eq("taskId", args.taskId).eq("status", "pending")
      )
      .collect();
    return reviews.map(serializeReview);
  },
});

/**
 * Get all completed reviews for a task, organized by taskRunId.
 * This is what the crown evaluator will use.
 */
export const getCompletedReviewsForCrownInternal = internalQuery({
  args: {
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args) => {
    const reviews = await ctx.db
      .query("parallelReviews")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .filter((q) => q.eq(q.field("status"), "completed"))
      .collect();

    // Group by taskRunId
    const byRun = new Map<
      string,
      Array<ReturnType<typeof serializeReview>>
    >();
    for (const review of reviews) {
      const runId = review.taskRunId;
      if (!byRun.has(runId)) {
        byRun.set(runId, []);
      }
      byRun.get(runId)!.push(serializeReview(review));
    }

    return Object.fromEntries(byRun);
  },
});

// ============================================================================
// Auth queries/mutations (for frontend use)
// ============================================================================

export const getReviewSetByTask = authQuery({
  args: {
    teamSlugOrId: v.string(),
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const set = await ctx.db
      .query("parallelReviewSets")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .filter((q) => q.eq(q.field("teamId"), teamId))
      .first();
    return set ? serializeReviewSet(set) : null;
  },
});

export const listReviewsByTask = authQuery({
  args: {
    teamSlugOrId: v.string(),
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const reviews = await ctx.db
      .query("parallelReviews")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .filter((q) => q.eq(q.field("teamId"), teamId))
      .collect();
    return reviews.map(serializeReview);
  },
});

export const listReviewsByTaskRun = authQuery({
  args: {
    teamSlugOrId: v.string(),
    taskRunId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const reviews = await ctx.db
      .query("parallelReviews")
      .withIndex("by_task_run", (q) => q.eq("taskRunId", args.taskRunId))
      .filter((q) => q.eq(q.field("teamId"), teamId))
      .collect();
    return reviews.map(serializeReview);
  },
});

/**
 * Manually trigger parallel reviews for a task.
 * Typically called after all task runs complete.
 */
export const triggerReviews = authMutation({
  args: {
    teamSlugOrId: v.string(),
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, args.teamSlugOrId);

    // Get the task
    const task = await ctx.db.get(args.taskId);
    if (!task || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }

    // Get completed runs for this task
    const taskRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .filter((q) =>
        q.and(
          q.eq(q.field("teamId"), teamId),
          q.eq(q.field("userId"), userId),
          q.eq(q.field("status"), "completed")
        )
      )
      .collect();

    if (taskRuns.length === 0) {
      throw new Error("No completed runs found for this task");
    }

    const taskRunIds = taskRuns.map((r) => r._id);

    // Create the review set
    const now = Date.now();
    const existingSet = await ctx.db
      .query("parallelReviewSets")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .first();

    if (existingSet) {
      return {
        reviewSetId: existingSet._id,
        reviewIds: [],
        alreadyExists: true,
      };
    }

    const reviewSetId = await ctx.db.insert("parallelReviewSets", {
      taskId: args.taskId,
      teamId,
      userId,
      status: "pending",
      taskRunIds,
      createdAt: now,
      updatedAt: now,
    });

    // Create individual review jobs
    const reviewIds: Id<"parallelReviews">[] = [];
    for (const taskRunId of taskRunIds) {
      for (const agent of REVIEWER_AGENTS) {
        const existingReview = await ctx.db
          .query("parallelReviews")
          .withIndex("by_task_run_agent", (q) =>
            q.eq("taskRunId", taskRunId).eq("reviewerAgent", agent)
          )
          .first();

        if (existingReview) {
          reviewIds.push(existingReview._id);
          continue;
        }

        const reviewId = await ctx.db.insert("parallelReviews", {
          taskId: args.taskId,
          taskRunId,
          teamId,
          userId,
          reviewerAgent: agent,
          status: "pending",
          createdAt: now,
          updatedAt: now,
        });
        reviewIds.push(reviewId);
      }
    }

    console.log(
      `[parallelReviews] Manual trigger created review set ${reviewSetId} with ${reviewIds.length} reviews`
    );

    return {
      reviewSetId,
      reviewIds,
      alreadyExists: false,
    };
  },
});
