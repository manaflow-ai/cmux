import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { action, internalMutation, internalQuery } from "./_generated/server";

export const createScreenshotSet = internalMutation({
  args: {
    previewRunId: v.id("previewRuns"),
    status: v.union(
      v.literal("completed"),
      v.literal("failed"),
      v.literal("skipped")
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
      })
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

/**
 * Public action for uploading screenshots and posting GitHub comment.
 * Used by the local preview script.
 */
export const uploadAndComment = action({
  args: {
    previewRunId: v.id("previewRuns"),
    status: v.union(
      v.literal("completed"),
      v.literal("failed"),
      v.literal("skipped")
    ),
    commitSha: v.string(),
    error: v.optional(v.string()),
    images: v.optional(
      v.array(
        v.object({
          storageId: v.string(),
          mimeType: v.string(),
          fileName: v.optional(v.string()),
          commitSha: v.string(),
          width: v.optional(v.number()),
          height: v.optional(v.number()),
        })
      )
    ),
  },
  returns: v.object({
    ok: v.boolean(),
    screenshotSetId: v.optional(v.string()),
    githubCommentUrl: v.optional(v.string()),
  }),
  handler: async (
    ctx,
    args
  ): Promise<{
    ok: boolean;
    screenshotSetId?: string;
    githubCommentUrl?: string;
  }> => {
    // Get the preview run to verify it exists and get team info
    const runData = await ctx.runQuery(internal.previewRuns.getRunWithConfig, {
      previewRunId: args.previewRunId,
    });

    if (!runData?.run) {
      throw new Error("Preview run not found");
    }

    const { run: previewRun } = runData;

    // Verify auth - user must have access to the team
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }

    // Convert string storageIds to proper typed IDs and create screenshot set
    const typedImages: Array<{
      storageId: Id<"_storage">;
      mimeType: string;
      fileName?: string;
      commitSha?: string;
      width?: number;
      height?: number;
    }> = (args.images ?? []).map((img) => ({
      storageId: img.storageId as unknown as Id<"_storage">,
      mimeType: img.mimeType,
      fileName: img.fileName,
      commitSha: img.commitSha,
      width: img.width,
      height: img.height,
    }));

    const screenshotSetId = await ctx.runMutation(
      internal.previewScreenshots.createScreenshotSet,
      {
        previewRunId: args.previewRunId,
        status: args.status,
        commitSha: args.commitSha,
        error: args.error,
        images: typedImages,
      }
    );

    // If we have an installation ID, post GitHub comment
    let githubCommentUrl: string | undefined;

    if (
      previewRun.repoInstallationId &&
      screenshotSetId &&
      args.status === "completed"
    ) {
      console.log(
        "[previewScreenshots] Posting GitHub comment for manual upload",
        {
          previewRunId: args.previewRunId,
          repoFullName: previewRun.repoFullName,
          prNumber: previewRun.prNumber,
        }
      );

      try {
        const commentResult = await ctx.runAction(
          internal.github_pr_comments.postPreviewCommentDirect,
          {
            installationId: previewRun.repoInstallationId,
            repoFullName: previewRun.repoFullName,
            prNumber: previewRun.prNumber,
            previewRunId: args.previewRunId,
            screenshotSetId,
          }
        );

        if (
          commentResult &&
          typeof commentResult === "object" &&
          "commentUrl" in commentResult
        ) {
          githubCommentUrl = commentResult.commentUrl as string;
        }
      } catch (error) {
        console.error(
          "[previewScreenshots] Failed to post GitHub comment:",
          error
        );
        // Don't throw - screenshot set was created successfully
      }
    } else if (!previewRun.repoInstallationId) {
      console.warn(
        "[previewScreenshots] No GitHub installation ID - cannot post comment",
        {
          previewRunId: args.previewRunId,
          repoFullName: previewRun.repoFullName,
        }
      );
    }

    return {
      ok: true,
      screenshotSetId: screenshotSetId as string,
      githubCommentUrl,
    };
  },
});

