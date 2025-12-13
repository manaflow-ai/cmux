import { v } from "convex/values";
import {
  PREVIEW_PAYWALL_FREE_PR_LIMIT,
  PREVIEW_PAYWALL_STATE_REASON,
} from "../_shared/preview-paywall";
import { getTeamId } from "../_shared/team";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { authMutation, authQuery } from "./users/utils";
import { internalMutation, internalQuery, type QueryCtx } from "./_generated/server";

function normalizeRepoFullName(value: string): string {
  return value.trim().replace(/\.git$/i, "").toLowerCase();
}

async function countUniquePullRequestsForUser(
  ctx: QueryCtx,
  userId: string,
  cap: number,
): Promise<number> {
  const maxUnique = Math.max(1, cap);
  const unique = new Set<string>();

  // Fetch enough runs to reliably count unique PRs up to the cap.
  // If a user has 10 unique PRs averaging ~5 runs each, we need ~50 runs.
  // Using 500 gives us margin for heavy users while avoiding pagination
  // (Convex doesn't allow multiple paginated queries in a single function).
  const runs = await ctx.db
    .query("previewRuns")
    .withIndex("by_user_created", (q) => q.eq("createdByUserId", userId))
    .order("desc")
    .take(500);

  for (const run of runs) {
    if (run.stateReason === PREVIEW_PAYWALL_STATE_REASON) {
      continue;
    }
    unique.add(`${run.repoFullName}#${run.prNumber}`);
    if (unique.size >= maxUnique) break;
  }

  return unique.size;
}

export const enqueueFromWebhook = internalMutation({
  args: {
    previewConfigId: v.id("previewConfigs"),
    teamId: v.string(),
    createdByUserId: v.string(),
    repoFullName: v.string(),
    repoInstallationId: v.optional(v.number()),
    prNumber: v.number(),
    prUrl: v.string(),
    prTitle: v.optional(v.string()),
    prDescription: v.optional(v.string()),
    headSha: v.string(),
    baseSha: v.optional(v.string()),
    headRef: v.optional(v.string()),
    headRepoFullName: v.optional(v.string()),
    headRepoCloneUrl: v.optional(v.string()),
    status: v.optional(
      v.union(
        v.literal("pending"),
        v.literal("running"),
        v.literal("completed"),
        v.literal("failed"),
        v.literal("skipped"),
      ),
    ),
    stateReason: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const repoFullName = normalizeRepoFullName(args.repoFullName);
    const headRepoFullName = args.headRepoFullName
      ? normalizeRepoFullName(args.headRepoFullName)
      : undefined;

    // Check if there's already a pending/running preview run for this PR
    // This prevents duplicate preview jobs when:
    // 1. Multiple webhooks fire for the same PR (e.g., synchronize events)
    // 2. Crown worker tries to create a preview run while one already exists
    const existingByPr = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr", (q) =>
        q.eq("previewConfigId", args.previewConfigId).eq("prNumber", args.prNumber),
      )
      .order("desc")
      .first();

    if (existingByPr && (existingByPr.status === "pending" || existingByPr.status === "running")) {
      console.log("[previewRuns] Returning existing pending/running preview run for PR", {
        existingRunId: existingByPr._id,
        prNumber: args.prNumber,
        existingHeadSha: existingByPr.headSha,
        newHeadSha: args.headSha,
        status: existingByPr.status,
      });
      return existingByPr._id;
    }

    // Avoid creating multiple paywall-skipped runs for the same PR.
    if (
      args.status === "skipped" &&
      args.stateReason === PREVIEW_PAYWALL_STATE_REASON &&
      existingByPr?.status === "skipped" &&
      existingByPr.stateReason === PREVIEW_PAYWALL_STATE_REASON
    ) {
      return existingByPr._id;
    }

    const now = Date.now();
    const status = args.status ?? "pending";
    const completedAt =
      status === "completed" || status === "failed" || status === "skipped"
        ? now
        : undefined;
    const runId = await ctx.db.insert("previewRuns", {
      previewConfigId: args.previewConfigId,
      teamId: args.teamId,
      createdByUserId: args.createdByUserId,
      repoFullName,
      repoInstallationId: args.repoInstallationId,
      prNumber: args.prNumber,
      prUrl: args.prUrl,
      prTitle: args.prTitle,
      prDescription: args.prDescription,
      headSha: args.headSha,
      baseSha: args.baseSha,
      headRef: args.headRef,
      headRepoFullName,
      headRepoCloneUrl: args.headRepoCloneUrl,
      status,
      stateReason: args.stateReason,
      dispatchedAt: undefined,
      startedAt: undefined,
      completedAt,
      screenshotSetId: undefined,
      githubCommentUrl: undefined,
      createdAt: now,
      updatedAt: now,
    });

    await ctx.db.patch(args.previewConfigId, {
      lastRunAt: now,
      updatedAt: now,
    });

    return runId;
  },
});

export const linkTaskRun = internalMutation({
  args: {
    previewRunId: v.id("previewRuns"),
    taskRunId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.previewRunId);
    if (!run) {
      throw new Error("Preview run not found");
    }
    await ctx.db.patch(run._id, {
      taskRunId: args.taskRunId,
      updatedAt: Date.now(),
    });
  },
});

/**
 * Called from crown worker completion to create/link a preview run for a task run.
 * This is used when a crown task completes with PR information and we want to
 * capture screenshots and post them to the PR.
 *
 * Returns:
 * - { created: true, previewRunId, isNew: true } if a new preview run was created
 * - { created: true, previewRunId, isNew: false } if linked to an existing pending/running run
 * - { created: false, reason: string } if no preview config exists or PR info missing
 */
export const enqueueFromTaskRun = internalMutation({
  args: {
    taskRunId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const taskRun = await ctx.db.get(args.taskRunId);
    if (!taskRun) {
      return { created: false, reason: "Task run not found" };
    }

    // Check if this taskRun is already linked to a preview run
    const existingLinkedRun = await ctx.db
      .query("previewRuns")
      .filter((q) => q.eq(q.field("taskRunId"), args.taskRunId))
      .first();

    if (existingLinkedRun) {
      console.log("[previewRuns] Task run already linked to preview run", {
        taskRunId: args.taskRunId,
        previewRunId: existingLinkedRun._id,
        status: existingLinkedRun.status,
      });
      return { created: true, previewRunId: existingLinkedRun._id, isNew: false };
    }

    // Get PR info from task run
    const prUrl = taskRun.pullRequestUrl;
    const prNumber = taskRun.pullRequestNumber;

    if (!prUrl || !prNumber) {
      console.log("[previewRuns] Task run missing PR info, skipping preview run creation", {
        taskRunId: args.taskRunId,
        hasPrUrl: Boolean(prUrl),
        hasPrNumber: Boolean(prNumber),
      });
      return { created: false, reason: "Task run missing PR info" };
    }

    // Get task to get projectFullName (repoFullName)
    const task = await ctx.db.get(taskRun.taskId);
    if (!task?.projectFullName) {
      console.log("[previewRuns] Task missing projectFullName, skipping preview run creation", {
        taskRunId: args.taskRunId,
        taskId: taskRun.taskId,
      });
      return { created: false, reason: "Task missing projectFullName" };
    }

    const repoFullName = normalizeRepoFullName(task.projectFullName);

    // Look up preview config for this team/repo
    const previewConfig = await ctx.db
      .query("previewConfigs")
      .withIndex("by_team_repo", (q) =>
        q.eq("teamId", taskRun.teamId).eq("repoFullName", repoFullName),
      )
      .first();

    if (!previewConfig) {
      console.log("[previewRuns] No preview config found for repo", {
        taskRunId: args.taskRunId,
        teamId: taskRun.teamId,
        repoFullName,
      });
      return { created: false, reason: "No preview config for repo" };
    }

    if (previewConfig.status === "disabled" || previewConfig.status === "paused") {
      console.log("[previewRuns] Preview config is disabled/paused", {
        taskRunId: args.taskRunId,
        previewConfigId: previewConfig._id,
        status: previewConfig.status,
      });
      return { created: false, reason: `Preview config is ${previewConfig.status}` };
    }

    // Check for existing pending/running preview run for this PR
    const existingByPr = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr", (q) =>
        q.eq("previewConfigId", previewConfig._id).eq("prNumber", prNumber),
      )
      .order("desc")
      .first();

    if (existingByPr && (existingByPr.status === "pending" || existingByPr.status === "running")) {
      console.log("[previewRuns] Found existing active preview run for PR, linking taskRun", {
        taskRunId: args.taskRunId,
        existingRunId: existingByPr._id,
        prNumber,
        status: existingByPr.status,
      });

      // Link this taskRun to the existing preview run if it doesn't have one
      if (!existingByPr.taskRunId) {
        await ctx.db.patch(existingByPr._id, {
          taskRunId: args.taskRunId,
          updatedAt: Date.now(),
        });
      }

      return { created: true, previewRunId: existingByPr._id, isNew: false };
    }

    // Extract headSha from newBranch or use a placeholder
    // In crown worker flow, we may not have the exact commit SHA
    const headSha = taskRun.newBranch ?? `taskrun-${args.taskRunId}`;

    // Try to get PR title from pullRequests table or task
    let prTitle: string | undefined;
    const prRecord = await ctx.db
      .query("pullRequests")
      .withIndex("by_team_repo_number", (q) =>
        q.eq("teamId", taskRun.teamId).eq("repoFullName", repoFullName).eq("number", prNumber),
      )
      .first();
    if (prRecord?.title) {
      prTitle = prRecord.title;
    } else if (task.pullRequestTitle) {
      prTitle = task.pullRequestTitle;
    }

    // Get PR description from task if available
    const prDescription = task.pullRequestDescription ?? undefined;

    const now = Date.now();
    const runId = await ctx.db.insert("previewRuns", {
      previewConfigId: previewConfig._id,
      teamId: taskRun.teamId,
      createdByUserId: taskRun.userId,
      repoFullName,
      repoInstallationId: previewConfig.repoInstallationId,
      prNumber,
      prUrl,
      prTitle,
      prDescription,
      headSha,
      baseSha: undefined,
      headRef: taskRun.newBranch ?? undefined,
      headRepoFullName: undefined,
      headRepoCloneUrl: undefined,
      taskRunId: args.taskRunId,
      status: "pending",
      dispatchedAt: undefined,
      startedAt: undefined,
      completedAt: undefined,
      screenshotSetId: undefined,
      githubCommentUrl: undefined,
      createdAt: now,
      updatedAt: now,
    });

    await ctx.db.patch(previewConfig._id, {
      lastRunAt: now,
      updatedAt: now,
    });

    console.log("[previewRuns] Created new preview run from task run", {
      taskRunId: args.taskRunId,
      previewRunId: runId,
      prNumber,
      prUrl,
      repoFullName,
    });

    return { created: true, previewRunId: runId, isNew: true };
  },
});

export const markDispatched = internalMutation({
  args: {
    previewRunId: v.id("previewRuns"),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.previewRunId);
    if (!run) {
      throw new Error("Preview run not found");
    }
    await ctx.db.patch(run._id, {
      status: "running",
      dispatchedAt: Date.now(),
      updatedAt: Date.now(),
    });
  },
});

export const updateStatus = internalMutation({
  args: {
    previewRunId: v.id("previewRuns"),
    status: v.union(
      v.literal("running"),
      v.literal("completed"),
      v.literal("failed"),
      v.literal("skipped"),
    ),
    screenshotSetId: v.optional(v.id("taskRunScreenshotSets")),
    githubCommentUrl: v.optional(v.string()),
    githubCommentId: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.previewRunId);
    if (!run) {
      throw new Error("Preview run not found");
    }
    const now = Date.now();
    const patch: Record<string, unknown> = {
      status: args.status,
      screenshotSetId: args.screenshotSetId,
      githubCommentUrl: args.githubCommentUrl ?? run.githubCommentUrl,
      githubCommentId: args.githubCommentId ?? run.githubCommentId,
      updatedAt: now,
    };
    if (args.status === "completed" || args.status === "failed" || args.status === "skipped") {
      patch.completedAt = now;
    } else if (args.status === "running" && !run.startedAt) {
      patch.startedAt = now;
    }
    await ctx.db.patch(run._id, patch);
  },
});

export const getById = internalQuery({
  args: {
    id: v.id("previewRuns"),
  },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.id);
  },
});

export const getRunWithConfig = internalQuery({
  args: {
    previewRunId: v.id("previewRuns"),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.previewRunId);
    if (!run) {
      return null;
    }
    const config = await ctx.db.get(run.previewConfigId);
    if (!config) {
      return null;
    }
    return { run, config } as const;
  },
});

export const getByTaskRunId = internalQuery({
  args: {
    taskRunId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db
      .query("previewRuns")
      .filter((q) => q.eq(q.field("taskRunId"), args.taskRunId))
      .first();
    return run ?? null;
  },
});

export const getActiveByConfigAndPr = internalQuery({
  args: {
    previewConfigId: v.id("previewConfigs"),
    prNumber: v.number(),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr", (q) =>
        q.eq("previewConfigId", args.previewConfigId).eq("prNumber", args.prNumber),
      )
      .order("desc")
      .first();

    if (run && (run.status === "pending" || run.status === "running")) {
      return run;
    }
    return null;
  },
});

export const listRecentByConfig = internalQuery({
  args: {
    previewConfigId: v.id("previewConfigs"),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const take = Math.max(1, Math.min(args.limit ?? 20, 100));
    const runs = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_status", (q) =>
        q.eq("previewConfigId", args.previewConfigId),
      )
      .order("desc")
      .take(take);
    return runs;
  },
});

export const listByConfigAndPr = internalQuery({
  args: {
    previewConfigId: v.id("previewConfigs"),
    prNumber: v.number(),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const take = Math.max(1, Math.min(args.limit ?? 20, 100));
    const runs = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr", (q) =>
        q.eq("previewConfigId", args.previewConfigId).eq("prNumber", args.prNumber),
      )
      .order("desc")
      .take(take);
    return runs;
  },
});

export const listByConfig = authQuery({
  args: {
    teamSlugOrId: v.string(),
    previewConfigId: v.id("previewConfigs"),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const config = await ctx.db.get(args.previewConfigId);
    if (!config || config.teamId !== teamId) {
      throw new Error("Preview configuration not found");
    }
    const take = Math.max(1, Math.min(args.limit ?? 25, 100));
    const runs = await ctx.db
      .query("previewRuns")
      .withIndex("by_team_created", (q) =>
        q.eq("teamId", teamId),
      )
      .filter((q) => q.eq(q.field("previewConfigId"), config._id))
      .order("desc")
      .take(take);
    return runs;
  },
});

export const listByTeam = authQuery({
  args: {
    teamSlugOrId: v.string(),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const take = Math.max(1, Math.min(args.limit ?? 50, 100));
    const runs = await ctx.db
      .query("previewRuns")
      .withIndex("by_team_created", (q) => q.eq("teamId", teamId))
      .order("desc")
      .take(take * 2); // Fetch extra to account for filtered archived tasks

    // Enrich with config repo name and taskId from linked taskRun
    // Also filter out runs whose linked task is archived
    const enrichedRuns: Array<
      (typeof runs)[number] & {
        configRepoFullName?: string;
        taskId?: Id<"tasks">;
      }
    > = [];

    for (const run of runs) {
      if (enrichedRuns.length >= take) break;

      const config = await ctx.db.get(run.previewConfigId);
      let taskId = undefined;
      let isTaskArchived = false;

      if (run.taskRunId) {
        const taskRun = await ctx.db.get(run.taskRunId);
        if (taskRun) {
          taskId = taskRun.taskId;
          // Check if the linked task is archived
          const task = await ctx.db.get(taskRun.taskId);
          isTaskArchived = task?.isArchived === true;
        }
      }

      // Skip runs whose linked task is archived
      if (isTaskArchived) continue;

      enrichedRuns.push({
        ...run,
        configRepoFullName: config?.repoFullName,
        taskId,
      });
    }

    return enrichedRuns;
  },
});

export const hasProcessedPullRequest = internalQuery({
  args: {
    previewConfigId: v.id("previewConfigs"),
    prNumber: v.number(),
  },
  handler: async (ctx, args) => {
    const runs = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr", (q) =>
        q.eq("previewConfigId", args.previewConfigId).eq("prNumber", args.prNumber),
      )
      .order("desc")
      .take(250);

    return runs.some((run) => run.stateReason !== PREVIEW_PAYWALL_STATE_REASON);
  },
});

/**
 * Check if there's already a paywall-blocked run for this PR.
 * Used to avoid posting duplicate paywall comments.
 */
export const hasPaywallRunForPullRequest = internalQuery({
  args: {
    previewConfigId: v.id("previewConfigs"),
    prNumber: v.number(),
  },
  handler: async (ctx, args) => {
    const runs = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr", (q) =>
        q.eq("previewConfigId", args.previewConfigId).eq("prNumber", args.prNumber),
      )
      .order("desc")
      .take(50);

    return runs.some((run) => run.stateReason === PREVIEW_PAYWALL_STATE_REASON);
  },
});

export const getUniquePullRequestCountByUser = internalQuery({
  args: {
    userId: v.string(),
    cap: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const cap = Math.max(1, Math.min(args.cap ?? PREVIEW_PAYWALL_FREE_PR_LIMIT, 10_000));
    return await countUniquePullRequestsForUser(ctx, args.userId, cap);
  },
});

export const getCurrentUserPreviewUsage = authQuery({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }

    const usedUniquePullRequests = await countUniquePullRequestsForUser(
      ctx,
      identity.subject,
      PREVIEW_PAYWALL_FREE_PR_LIMIT,
    );

    return {
      usedUniquePullRequests,
      freeLimit: PREVIEW_PAYWALL_FREE_PR_LIMIT,
    };
  },
});

/**
 * Create a preview run manually (for local preview scripts).
 * Follows the same flow as the GitHub webhook handler:
 * 1. Creates or reuses a preview run
 * 2. Creates a task and taskRun
 * 3. Links the taskRun to the preview run
 *
 * Requires an existing previewConfig for the repo.
 */
export const createManual = authMutation({
  args: {
    teamSlugOrId: v.string(),
    repoFullName: v.string(),
    prNumber: v.number(),
    prUrl: v.string(),
    prTitle: v.optional(v.string()),
    prDescription: v.optional(v.string()),
    headSha: v.string(),
    baseSha: v.optional(v.string()),
    headRef: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const repoFullName = normalizeRepoFullName(args.repoFullName);

    // Find the preview config for this repo
    const config = await ctx.db
      .query("previewConfigs")
      .withIndex("by_team_repo", (q) =>
        q.eq("teamId", teamId).eq("repoFullName", repoFullName),
      )
      .first();

    if (!config) {
      throw new Error(
        `No preview configuration found for ${repoFullName}. ` +
        `Please create one first via the cmux UI.`,
      );
    }

    // Check for existing pending/running run for this PR (similar to webhook flow)
    const existingByPr = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr", (q) =>
        q.eq("previewConfigId", config._id).eq("prNumber", args.prNumber),
      )
      .order("desc")
      .first();

    if (
      existingByPr &&
      existingByPr.taskRunId &&
      (existingByPr.status === "pending" || existingByPr.status === "running")
    ) {
      // Return existing run only if it has a taskRun linked
      return { previewRunId: existingByPr._id, reused: true };
    }

    const now = Date.now();

    // Step 1: Create preview run (following enqueueFromWebhook pattern)
    const runId = await ctx.db.insert("previewRuns", {
      previewConfigId: config._id,
      teamId,
      createdByUserId: config.createdByUserId,
      repoFullName,
      repoInstallationId: config.repoInstallationId,
      prNumber: args.prNumber,
      prUrl: args.prUrl,
      prTitle: args.prTitle,
      prDescription: args.prDescription,
      headSha: args.headSha,
      baseSha: args.baseSha,
      headRef: args.headRef,
      headRepoFullName: undefined,
      headRepoCloneUrl: undefined,
      status: "running", // Start as running since we're doing local capture
      stateReason: "Manual local preview",
      dispatchedAt: now,
      startedAt: now,
      completedAt: undefined,
      screenshotSetId: undefined,
      githubCommentUrl: undefined,
      createdAt: now,
      updatedAt: now,
    });

    await ctx.db.patch(config._id, {
      lastRunAt: now,
      updatedAt: now,
    });

    // Step 2: Get user ID from auth context
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }
    const userId = config.createdByUserId;

    // Step 3: Create task for this preview run (following webhook pattern)
    const taskId = await ctx.runMutation(internal.tasks.createForPreview, {
      teamId,
      userId,
      previewRunId: runId,
      repoFullName,
      prNumber: args.prNumber,
      prUrl: args.prUrl,
      headSha: args.headSha,
      baseBranch: config.repoDefaultBranch,
    });

    // Step 4: Create taskRun (following webhook pattern)
    const { taskRunId } = await ctx.runMutation(internal.taskRuns.createForPreview, {
      taskId,
      teamId,
      userId,
      prUrl: args.prUrl,
      environmentId: config.environmentId,
      newBranch: args.headRef,
    });

    // Step 5: Link the taskRun to the preview run
    await ctx.runMutation(internal.previewRuns.linkTaskRun, {
      previewRunId: runId,
      taskRunId,
    });

    return { previewRunId: runId, reused: false };
  },
});
