import { paginationOptsValidator } from "convex/server";
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

async function countUniquePullRequestsForTeam(
  ctx: QueryCtx,
  teamId: string,
  cap: number,
): Promise<number> {
  const maxUnique = Math.max(1, cap);
  const unique = new Set<string>();

  // Fetch enough runs to reliably count unique PRs up to the cap.
  // If a team has 10 unique PRs averaging ~5 runs each, we need ~50 runs.
  // Using 500 gives us margin for heavy users while avoiding pagination
  // (Convex doesn't allow multiple paginated queries in a single function).
  const runs = await ctx.db
    .query("previewRuns")
    .withIndex("by_team_created", (q) => q.eq("teamId", teamId))
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

    // Check if there's already a preview run for this exact PR + commit combination
    // This prevents duplicate jobs for the SAME commit (e.g., multiple webhooks for same push)
    const existingForSameCommit = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr_head", (q) =>
        q
          .eq("previewConfigId", args.previewConfigId)
          .eq("prNumber", args.prNumber)
          .eq("headSha", args.headSha),
      )
      .first();

    if (
      existingForSameCommit &&
      (existingForSameCommit.status === "pending" || existingForSameCommit.status === "running")
    ) {
      console.log("[previewRuns] Returning existing preview run for same PR + commit", {
        existingRunId: existingForSameCommit._id,
        prNumber: args.prNumber,
        headSha: args.headSha,
        status: existingForSameCommit.status,
      });
      return existingForSameCommit._id;
    }

    // Find any pending/running preview runs for this PR with DIFFERENT commits
    // These will be superseded by the new run
    const existingRunsForPr = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr", (q) =>
        q.eq("previewConfigId", args.previewConfigId).eq("prNumber", args.prNumber),
      )
      .order("desc")
      .collect();

    const runsToSupersede = existingRunsForPr.filter(
      (run) =>
        run.headSha !== args.headSha &&
        (run.status === "pending" || run.status === "running"),
    );

    const now = Date.now();
    const status = args.status ?? "pending";
    const completedAt =
      status === "completed" || status === "failed" || status === "skipped"
        ? now
        : undefined;

    // Create the new preview run for this commit
    const runId = await ctx.db.insert("previewRuns", {
      previewConfigId: args.previewConfigId,
      teamId: args.teamId,
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

    // Mark older runs as superseded by this new run
    for (const oldRun of runsToSupersede) {
      console.log("[previewRuns] Superseding older preview run", {
        oldRunId: oldRun._id,
        oldHeadSha: oldRun.headSha,
        oldStatus: oldRun.status,
        newRunId: runId,
        newHeadSha: args.headSha,
        prNumber: args.prNumber,
      });
      await ctx.db.patch(oldRun._id, {
        status: "superseded",
        supersededBy: runId,
        stateReason: `Superseded by newer commit ${args.headSha.slice(0, 7)}`,
        completedAt: now,
        updatedAt: now,
      });
    }

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

    // Try to get PR info from pullRequests table (has the actual commit SHA from GitHub)
    const prRecord = await ctx.db
      .query("pullRequests")
      .withIndex("by_team_repo_number", (q) =>
        q.eq("teamId", taskRun.teamId).eq("repoFullName", repoFullName).eq("number", prNumber),
      )
      .first();

    // Extract headSha from PR record (preferred), taskRun.newBranch, or use placeholder
    // The PR record's headSha is the actual commit SHA from GitHub webhook, which is what
    // we want for proper commit-aware deduplication with webhook-initiated preview runs.
    // Using the branch name (taskRun.newBranch) would cause mismatches because webhooks use SHA.
    const headSha = prRecord?.headSha ?? taskRun.newBranch ?? `taskrun-${args.taskRunId}`;
    const baseSha = prRecord?.baseSha;

    console.log("[previewRuns] Resolved headSha for taskRun", {
      taskRunId: args.taskRunId,
      prNumber,
      headSha,
      source: prRecord?.headSha ? "pr_record" : taskRun.newBranch ? "task_run_branch" : "fallback",
      hasPrRecord: Boolean(prRecord),
    });

    // Check if there's already a preview run for this exact PR + commit combination
    // This prevents duplicate jobs for the SAME commit
    const existingForSameCommit = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr_head", (q) =>
        q
          .eq("previewConfigId", previewConfig._id)
          .eq("prNumber", prNumber)
          .eq("headSha", headSha),
      )
      .first();

    if (
      existingForSameCommit &&
      (existingForSameCommit.status === "pending" || existingForSameCommit.status === "running")
    ) {
      console.log("[previewRuns] Found existing preview run for same PR + commit, linking taskRun", {
        taskRunId: args.taskRunId,
        existingRunId: existingForSameCommit._id,
        prNumber,
        headSha,
        status: existingForSameCommit.status,
      });

      // Link this taskRun to the existing preview run if it doesn't have one
      if (!existingForSameCommit.taskRunId) {
        await ctx.db.patch(existingForSameCommit._id, {
          taskRunId: args.taskRunId,
          updatedAt: Date.now(),
        });
      }

      return { created: true, previewRunId: existingForSameCommit._id, isNew: false };
    }

    // Find any pending/running preview runs for this PR with DIFFERENT commits
    // These will be superseded by the new run
    const existingRunsForPr = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr", (q) =>
        q.eq("previewConfigId", previewConfig._id).eq("prNumber", prNumber),
      )
      .order("desc")
      .collect();

    const runsToSupersede = existingRunsForPr.filter(
      (run) =>
        run.headSha !== headSha &&
        (run.status === "pending" || run.status === "running"),
    );

    // Get PR title from the already-fetched prRecord or task
    let prTitle: string | undefined;
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
      repoFullName,
      repoInstallationId: previewConfig.repoInstallationId,
      prNumber,
      prUrl,
      prTitle,
      prDescription,
      headSha,
      baseSha,
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

    // Mark older runs as superseded by this new run
    for (const oldRun of runsToSupersede) {
      console.log("[previewRuns] Superseding older preview run (from taskRun)", {
        oldRunId: oldRun._id,
        oldHeadSha: oldRun.headSha,
        oldStatus: oldRun.status,
        newRunId: runId,
        newHeadSha: headSha,
        prNumber,
      });
      await ctx.db.patch(oldRun._id, {
        status: "superseded",
        supersededBy: runId,
        stateReason: `Superseded by newer commit ${headSha.slice(0, 7)}`,
        completedAt: now,
        updatedAt: now,
      });
    }

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
      supersededCount: runsToSupersede.length,
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
      v.literal("superseded"),
    ),
    screenshotSetId: v.optional(v.id("taskRunScreenshotSets")),
    githubCommentUrl: v.optional(v.string()),
    githubCommentId: v.optional(v.number()),
    stateReason: v.optional(v.string()),
    supersededBy: v.optional(v.id("previewRuns")),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.previewRunId);
    if (!run) {
      throw new Error("Preview run not found");
    }
    const now = Date.now();

    // Preserve "superseded" status - don't allow overwriting it with other statuses
    // A superseded run should stay superseded even if it completes its work.
    // The exception is when explicitly setting to "superseded" (args.status === "superseded").
    const shouldPreserveSuperseded =
      run.status === "superseded" && args.status !== "superseded";
    const effectiveStatus = shouldPreserveSuperseded ? run.status : args.status;

    if (shouldPreserveSuperseded) {
      console.log("[previewRuns] Preserving superseded status", {
        previewRunId: args.previewRunId,
        attemptedStatus: args.status,
        currentStatus: run.status,
      });
    }

    const patch: Record<string, unknown> = {
      status: effectiveStatus,
      screenshotSetId: args.screenshotSetId ?? run.screenshotSetId,
      githubCommentUrl: args.githubCommentUrl ?? run.githubCommentUrl,
      githubCommentId: args.githubCommentId ?? run.githubCommentId,
      updatedAt: now,
    };
    if (args.stateReason !== undefined) {
      patch.stateReason = args.stateReason;
    }
    if (args.supersededBy !== undefined) {
      patch.supersededBy = args.supersededBy;
    }
    if (
      args.status === "completed" ||
      args.status === "failed" ||
      args.status === "skipped" ||
      args.status === "superseded"
    ) {
      // Only set completedAt if not already set (preserve original completion time for superseded runs)
      if (!run.completedAt) {
        patch.completedAt = now;
      }
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

/**
 * Check if a preview run has been superseded by a newer commit.
 * Used by the worker to detect mid-execution supersession and abort early.
 * Returns true if the run is superseded or no longer exists.
 */
export const checkIfSuperseded = internalQuery({
  args: {
    previewRunId: v.id("previewRuns"),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.previewRunId);
    if (!run) {
      // Run doesn't exist - treat as superseded to stop processing
      return { superseded: true, reason: "run_not_found" };
    }
    if (run.status === "superseded") {
      return {
        superseded: true,
        reason: "superseded_by_newer_commit",
        supersededBy: run.supersededBy,
        stateReason: run.stateReason,
      };
    }
    return { superseded: false };
  },
});

/**
 * Get the active preview run for a specific PR + commit combination.
 * This is commit-aware and will only return runs for the exact commit SHA.
 */
export const getActiveByConfigPrAndCommit = internalQuery({
  args: {
    previewConfigId: v.id("previewConfigs"),
    prNumber: v.number(),
    headSha: v.string(),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db
      .query("previewRuns")
      .withIndex("by_config_pr_head", (q) =>
        q
          .eq("previewConfigId", args.previewConfigId)
          .eq("prNumber", args.prNumber)
          .eq("headSha", args.headSha),
      )
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

export const getUniquePullRequestCountByTeam = internalQuery({
  args: {
    teamId: v.string(),
    cap: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const cap = Math.max(1, Math.min(args.cap ?? PREVIEW_PAYWALL_FREE_PR_LIMIT, 10_000));
    return await countUniquePullRequestsForTeam(ctx, args.teamId, cap);
  },
});

export const getTeamPreviewUsage = authQuery({
  args: {
    teamSlugOrId: v.string(),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);

    const usedUniquePullRequests = await countUniquePullRequestsForTeam(
      ctx,
      teamId,
      PREVIEW_PAYWALL_FREE_PR_LIMIT,
    );

    return {
      teamId,
      usedUniquePullRequests,
      freeLimit: PREVIEW_PAYWALL_FREE_PR_LIMIT,
    };
  },
});

// Paginated query for preview runs (infinite scroll)
export const listByTeamPaginated = authQuery({
  args: {
    teamSlugOrId: v.string(),
    paginationOpts: paginationOptsValidator,
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);

    // Query preview runs with pagination
    const paginatedResult = await ctx.db
      .query("previewRuns")
      .withIndex("by_team_created", (q) => q.eq("teamId", teamId))
      .order("desc")
      .paginate(args.paginationOpts);

    // Enrich with config repo name and taskId from linked taskRun
    // Also filter out runs whose linked task is archived
    const enrichedPage: Array<
      (typeof paginatedResult.page)[number] & {
        configRepoFullName?: string;
        taskId?: Id<"tasks">;
      }
    > = [];

    for (const run of paginatedResult.page) {
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

      enrichedPage.push({
        ...run,
        configRepoFullName: config?.repoFullName,
        taskId,
      });
    }

    return {
      ...paginatedResult,
      page: enrichedPage,
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
    const userId = identity.subject;

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
