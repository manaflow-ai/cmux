import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction, internalMutation, internalQuery } from "./_generated/server";

export const createScreenshotSet = internalMutation({
  args: {
    previewRunId: v.id("previewRuns"),
    status: v.union(
      v.literal("completed"),
      v.literal("failed"),
      v.literal("skipped"),
    ),
    commitSha: v.string(),
    error: v.optional(v.string()),
    images: v.array(
      v.object({
        storageId: v.id("_storage"),
        mimeType: v.string(),
        fileName: v.optional(v.string()),
        commitSha: v.optional(v.string()),
        width: v.optional(v.number()),
        height: v.optional(v.number()),
      }),
    ),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.previewRunId);
    if (!run) {
      throw new Error("Preview run not found");
    }

    const now = Date.now();
    const screenshotSetId = await ctx.db.insert("previewScreenshotSets", {
      previewRunId: args.previewRunId,
      status: args.status,
      commitSha: args.commitSha,
      capturedAt: now,
      error: args.error,
      images: args.images,
      createdAt: now,
      updatedAt: now,
    });

    await ctx.db.patch(args.previewRunId, {
      screenshotSetId,
      updatedAt: now,
    });

    return screenshotSetId;
  },
});

export const getScreenshotSet = internalQuery({
  args: {
    screenshotSetId: v.id("previewScreenshotSets"),
  },
  handler: async (ctx, args) => {
    const set = await ctx.db.get(args.screenshotSetId);
    return set ?? null;
  },
});

export const getScreenshotSetByRun = internalQuery({
  args: {
    previewRunId: v.id("previewRuns"),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.previewRunId);
    if (!run?.screenshotSetId) {
      return null;
    }
    return await ctx.db.get(run.screenshotSetId);
  },
});

export const triggerGithubComment = internalAction({
  args: {
    previewRunId: v.id("previewRuns"),
  },
  handler: async (ctx, args) => {
    console.log("[previewScreenshots] Triggering GitHub comment", {
      previewRunId: args.previewRunId,
    });

    const run = await ctx.runQuery(internal.previewRuns.getRunWithConfig, {
      previewRunId: args.previewRunId,
    });

    if (!run?.run || !run.config) {
      console.error("[previewScreenshots] Run or config not found", {
        previewRunId: args.previewRunId,
      });
      return;
    }

    const { run: previewRun } = run;

    if (!previewRun.screenshotSetId) {
      console.warn("[previewScreenshots] No screenshot set for run", {
        previewRunId: args.previewRunId,
      });
      return;
    }

    if (!previewRun.repoInstallationId) {
      console.error("[previewScreenshots] No installation ID for run", {
        previewRunId: args.previewRunId,
      });
      return;
    }

    console.log("[previewScreenshots] Posting GitHub comment", {
      previewRunId: args.previewRunId,
      repoFullName: previewRun.repoFullName,
      prNumber: previewRun.prNumber,
      screenshotSetId: previewRun.screenshotSetId,
    });

    // Post GitHub comment with screenshots
    await ctx.runAction(internal.github_pr_comments.postPreviewComment, {
      installationId: previewRun.repoInstallationId,
      repoFullName: previewRun.repoFullName,
      prNumber: previewRun.prNumber,
      screenshotSetId: previewRun.screenshotSetId,
      previewRunId: args.previewRunId,
    });

    console.log("[previewScreenshots] GitHub comment posted successfully", {
      previewRunId: args.previewRunId,
    });
  },
});
