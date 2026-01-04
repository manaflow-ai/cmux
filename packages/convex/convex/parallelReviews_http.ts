import { z } from "zod";
import type { Id } from "./_generated/dataModel";
import { httpAction } from "./_generated/server";
import { internal } from "./_generated/api";
import { getWorkerAuth } from "./users/utils/getWorkerAuth";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

async function ensureJsonRequest(
  req: Request
): Promise<{ json: unknown } | Response> {
  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return jsonResponse(
      { code: 415, message: "Content-Type must be application/json" },
      415
    );
  }

  try {
    const json = await req.json();
    return { json };
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON body" }, 400);
  }
}

// Schemas for request validation
const TriggerReviewsSchema = z.object({
  taskId: z.string(),
  taskRunIds: z.array(z.string()).optional(),
  reviewerAgents: z.array(z.enum(["claude", "codex", "gemini"])).optional(),
});

const StartReviewSchema = z.object({
  reviewId: z.string(),
  sandboxInstanceId: z.string().optional(),
});

const CompleteReviewSchema = z.object({
  reviewId: z.string(),
  reviewOutput: z.string(),
  score: z.number().min(0).max(100).optional(),
  strengths: z.array(z.string()).optional(),
  weaknesses: z.array(z.string()).optional(),
  suggestions: z.array(z.string()).optional(),
  sandboxInstanceId: z.string().optional(),
});

const FailReviewSchema = z.object({
  reviewId: z.string(),
  errorCode: z.string(),
  errorDetail: z.string().optional(),
  sandboxInstanceId: z.string().optional(),
});

const GetReviewsSchema = z.object({
  taskId: z.string().optional(),
  taskRunId: z.string().optional(),
});

const CheckReviewsSchema = z.object({
  taskId: z.string(),
});

/**
 * POST /api/parallel-reviews/trigger
 * Trigger parallel reviews for a task after all runs complete.
 * Called by the worker after task completion detection.
 */
export const triggerParallelReviews = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, {
    loggerPrefix: "[parallelReviews]",
  });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = TriggerReviewsSchema.safeParse(parsed.json);
  if (!validation.success) {
    console.warn(
      "[parallelReviews] Invalid trigger payload",
      validation.error.issues
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const { taskId, taskRunIds, reviewerAgents } = validation.data;

  // Verify task belongs to worker's team
  const task = await ctx.runQuery(internal.tasks.getByIdInternal, {
    id: taskId as Id<"tasks">,
  });

  if (!task) {
    return jsonResponse({ code: 404, message: "Task not found" }, 404);
  }

  if (
    task.teamId !== auth.payload.teamId ||
    task.userId !== auth.payload.userId
  ) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  // Get completed runs if not provided
  let runIds = taskRunIds as Id<"taskRuns">[] | undefined;
  if (!runIds || runIds.length === 0) {
    const runs = await ctx.runQuery(
      internal.taskRuns.listByTaskAndTeamInternal,
      {
        taskId: taskId as Id<"tasks">,
        teamId: auth.payload.teamId,
        userId: auth.payload.userId,
      }
    );

    runIds = runs
      .filter((r) => r.status === "completed")
      .map((r) => r._id as Id<"taskRuns">);
  }

  if (runIds.length === 0) {
    return jsonResponse(
      { code: 400, message: "No completed runs to review" },
      400
    );
  }

  try {
    const result = await ctx.runMutation(
      internal.parallelReviews.createReviewSet,
      {
        taskId: taskId as Id<"tasks">,
        taskRunIds: runIds,
        teamId: auth.payload.teamId,
        userId: auth.payload.userId,
        reviewerAgents,
      }
    );

    console.log("[parallelReviews] Triggered reviews", {
      taskId,
      reviewSetId: result.reviewSetId,
      reviewCount: result.reviewIds.length,
      alreadyExists: result.alreadyExists,
    });

    return jsonResponse({
      ok: true,
      reviewSetId: result.reviewSetId,
      reviewIds: result.reviewIds,
      alreadyExists: result.alreadyExists,
    });
  } catch (error) {
    console.error("[parallelReviews] Failed to trigger reviews", error);
    return jsonResponse(
      { code: 500, message: "Failed to trigger reviews" },
      500
    );
  }
});

/**
 * POST /api/parallel-reviews/start
 * Mark a review as running when agent sandbox starts
 */
export const startReview = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, {
    loggerPrefix: "[parallelReviews]",
  });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = StartReviewSchema.safeParse(parsed.json);
  if (!validation.success) {
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const { reviewId, sandboxInstanceId } = validation.data;

  // Verify review belongs to worker's team
  const review = await ctx.runQuery(
    internal.parallelReviews.getReviewByIdInternal,
    {
      reviewId: reviewId as Id<"parallelReviews">,
    }
  );

  if (!review) {
    return jsonResponse({ code: 404, message: "Review not found" }, 404);
  }

  if (review.teamId !== auth.payload.teamId) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  try {
    const result = await ctx.runMutation(
      internal.parallelReviews.markReviewRunning,
      {
        reviewId: reviewId as Id<"parallelReviews">,
        sandboxInstanceId,
      }
    );

    return jsonResponse({ ok: true, review: result });
  } catch (error) {
    console.error("[parallelReviews] Failed to start review", error);
    return jsonResponse({ code: 500, message: "Failed to start review" }, 500);
  }
});

/**
 * POST /api/parallel-reviews/complete
 * Complete a review with results from the agent
 */
export const completeParallelReview = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, {
    loggerPrefix: "[parallelReviews]",
  });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = CompleteReviewSchema.safeParse(parsed.json);
  if (!validation.success) {
    console.warn(
      "[parallelReviews] Invalid complete payload",
      validation.error.issues
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const {
    reviewId,
    reviewOutput,
    score,
    strengths,
    weaknesses,
    suggestions,
    sandboxInstanceId,
  } = validation.data;

  // Verify review belongs to worker's team
  const review = await ctx.runQuery(
    internal.parallelReviews.getReviewByIdInternal,
    {
      reviewId: reviewId as Id<"parallelReviews">,
    }
  );

  if (!review) {
    return jsonResponse({ code: 404, message: "Review not found" }, 404);
  }

  if (review.teamId !== auth.payload.teamId) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  try {
    const result = await ctx.runMutation(
      internal.parallelReviews.completeReview,
      {
        reviewId: reviewId as Id<"parallelReviews">,
        reviewOutput,
        score,
        strengths,
        weaknesses,
        suggestions,
        sandboxInstanceId,
      }
    );

    console.log("[parallelReviews] Completed review", {
      reviewId,
      reviewerAgent: review.reviewerAgent,
      score,
    });

    return jsonResponse({ ok: true, review: result });
  } catch (error) {
    console.error("[parallelReviews] Failed to complete review", error);
    return jsonResponse(
      { code: 500, message: "Failed to complete review" },
      500
    );
  }
});

/**
 * POST /api/parallel-reviews/fail
 * Mark a review as failed
 */
export const failParallelReview = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, {
    loggerPrefix: "[parallelReviews]",
  });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = FailReviewSchema.safeParse(parsed.json);
  if (!validation.success) {
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const { reviewId, errorCode, errorDetail, sandboxInstanceId } =
    validation.data;

  // Verify review belongs to worker's team
  const review = await ctx.runQuery(
    internal.parallelReviews.getReviewByIdInternal,
    {
      reviewId: reviewId as Id<"parallelReviews">,
    }
  );

  if (!review) {
    return jsonResponse({ code: 404, message: "Review not found" }, 404);
  }

  if (review.teamId !== auth.payload.teamId) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  try {
    const result = await ctx.runMutation(internal.parallelReviews.failReview, {
      reviewId: reviewId as Id<"parallelReviews">,
      errorCode,
      errorDetail,
      sandboxInstanceId,
    });

    console.log("[parallelReviews] Failed review", {
      reviewId,
      errorCode,
    });

    return jsonResponse({ ok: true, review: result });
  } catch (error) {
    console.error("[parallelReviews] Failed to fail review", error);
    return jsonResponse({ code: 500, message: "Failed to update review" }, 500);
  }
});

/**
 * POST /api/parallel-reviews/list
 * Get reviews for a task or task run
 */
export const listParallelReviews = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, {
    loggerPrefix: "[parallelReviews]",
  });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = GetReviewsSchema.safeParse(parsed.json);
  if (!validation.success) {
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const { taskId, taskRunId } = validation.data;

  if (!taskId && !taskRunId) {
    return jsonResponse(
      { code: 400, message: "taskId or taskRunId required" },
      400
    );
  }

  try {
    let reviews;
    if (taskRunId) {
      reviews = await ctx.runQuery(
        internal.parallelReviews.listReviewsByTaskRunInternal,
        { taskRunId: taskRunId as Id<"taskRuns"> }
      );
    } else {
      reviews = await ctx.runQuery(
        internal.parallelReviews.listReviewsByTaskInternal,
        { taskId: taskId as Id<"tasks"> }
      );
    }

    // Filter to worker's team
    const filtered = reviews.filter(
      (r) => r.teamId === auth.payload.teamId
    );

    return jsonResponse({ ok: true, reviews: filtered });
  } catch (error) {
    console.error("[parallelReviews] Failed to list reviews", error);
    return jsonResponse({ code: 500, message: "Failed to list reviews" }, 500);
  }
});

/**
 * POST /api/parallel-reviews/check
 * Check status of all reviews for a task (used by crown worker to poll)
 */
export const checkParallelReviews = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, {
    loggerPrefix: "[parallelReviews]",
  });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = CheckReviewsSchema.safeParse(parsed.json);
  if (!validation.success) {
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const { taskId } = validation.data;

  try {
    // Get review set
    const reviewSet = await ctx.runQuery(
      internal.parallelReviews.getReviewSetByTaskInternal,
      { taskId: taskId as Id<"tasks"> }
    );

    if (!reviewSet) {
      return jsonResponse({
        ok: true,
        hasReviews: false,
        allComplete: false,
        reviews: [],
      });
    }

    if (reviewSet.teamId !== auth.payload.teamId) {
      return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
    }

    // Get all reviews
    const reviews = await ctx.runQuery(
      internal.parallelReviews.listReviewsByTaskInternal,
      { taskId: taskId as Id<"tasks"> }
    );

    const allComplete = reviews.every(
      (r) => r.status === "completed" || r.status === "failed"
    );
    const completedReviews = reviews.filter((r) => r.status === "completed");

    return jsonResponse({
      ok: true,
      hasReviews: true,
      reviewSetId: reviewSet.id,
      reviewSetStatus: reviewSet.status,
      allComplete,
      completedCount: completedReviews.length,
      totalCount: reviews.length,
      aggregatedSummary: reviewSet.aggregatedSummary,
      reviews: reviews.map((r) => ({
        id: r.id,
        taskRunId: r.taskRunId,
        reviewerAgent: r.reviewerAgent,
        status: r.status,
        score: r.score,
        hasOutput: Boolean(r.reviewOutput),
      })),
    });
  } catch (error) {
    console.error("[parallelReviews] Failed to check reviews", error);
    return jsonResponse({ code: 500, message: "Failed to check reviews" }, 500);
  }
});

/**
 * POST /api/parallel-reviews/get-for-crown
 * Get completed reviews formatted for the crown evaluator
 */
export const getReviewsForCrown = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, {
    loggerPrefix: "[parallelReviews]",
  });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = CheckReviewsSchema.safeParse(parsed.json);
  if (!validation.success) {
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const { taskId } = validation.data;

  try {
    // Verify task belongs to worker
    const task = await ctx.runQuery(internal.tasks.getByIdInternal, {
      id: taskId as Id<"tasks">,
    });

    if (!task) {
      return jsonResponse({ code: 404, message: "Task not found" }, 404);
    }

    if (
      task.teamId !== auth.payload.teamId ||
      task.userId !== auth.payload.userId
    ) {
      return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
    }

    const reviewsByRun = await ctx.runQuery(
      internal.parallelReviews.getCompletedReviewsForCrownInternal,
      { taskId: taskId as Id<"tasks"> }
    );

    return jsonResponse({
      ok: true,
      reviewsByRun,
    });
  } catch (error) {
    console.error("[parallelReviews] Failed to get reviews for crown", error);
    return jsonResponse(
      { code: 500, message: "Failed to get reviews" },
      500
    );
  }
});
