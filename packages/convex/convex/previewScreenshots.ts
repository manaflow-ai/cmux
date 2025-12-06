import { v } from "convex/values";
import { internal } from "./_generated/api";
import {
  action,
  internalAction,
  internalMutation,
  internalQuery,
} from "./_generated/server";
import type { Id } from "./_generated/dataModel";

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
    hasUiChanges: v.optional(v.boolean()),
    images: v.array(
      v.object({
        storageId: v.id("_storage"),
        mimeType: v.string(),
        fileName: v.optional(v.string()),
        commitSha: v.optional(v.string()),
        width: v.optional(v.number()),
        height: v.optional(v.number()),
        description: v.optional(v.string()),
      })
    ),
  },
  handler: async (ctx, args): Promise<Id<"taskRunScreenshotSets">> => {
    const previewRun = await ctx.db.get(args.previewRunId);
    if (!previewRun) {
      throw new Error("Preview run not found");
    }

    if (!previewRun.taskRunId) {
      throw new Error("Preview run is not linked to a task run");
    }

    const taskRun = await ctx.db.get(previewRun.taskRunId);
    if (!taskRun) {
      throw new Error("Task run not found for preview run");
    }

    if (args.status === "completed" && args.images.length === 0) {
      throw new Error(
        "At least one screenshot is required for completed status"
      );
    }

    const screenshots = args.images.map((image) => ({
      storageId: image.storageId,
      mimeType: image.mimeType,
      fileName: image.fileName,
      commitSha: image.commitSha ?? args.commitSha,
      description: image.description,
    }));

    const screenshotSetId: Id<"taskRunScreenshotSets"> = await ctx.runMutation(
      internal.tasks.recordScreenshotResult,
      {
        taskId: taskRun.taskId,
        runId: taskRun._id,
        status: args.status,
        commitSha: args.commitSha,
        hasUiChanges: args.hasUiChanges,
        screenshots,
        error: args.error,
      }
    );

    const primaryScreenshot = screenshots[0];
    if (primaryScreenshot) {
      await ctx.runMutation(internal.taskRuns.updateScreenshotMetadata, {
        id: taskRun._id,
        storageId: primaryScreenshot.storageId,
        mimeType: primaryScreenshot.mimeType,
        fileName: primaryScreenshot.fileName,
        commitSha: primaryScreenshot.commitSha,
        screenshotSetId,
      });
    } else if (args.status !== "completed") {
      await ctx.runMutation(internal.taskRuns.clearScreenshotMetadata, {
        id: taskRun._id,
      });
    }

    await ctx.db.patch(args.previewRunId, {
      screenshotSetId,
      updatedAt: Date.now(),
    });

    return screenshotSetId;
  },
});

export const getScreenshotSet = internalQuery({
  args: {
    screenshotSetId: v.id("taskRunScreenshotSets"),
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

    await ctx.runAction(internal.github_pr_comments.postPreviewComment, {
      installationId: previewRun.repoInstallationId,
      repoFullName: previewRun.repoFullName,
      prNumber: previewRun.prNumber,
      screenshotSetId: previewRun.screenshotSetId,
      previewRunId: args.previewRunId,
      includePreviousRuns: true,
      previewConfigId: previewRun.previewConfigId,
    });

    console.log("[previewScreenshots] GitHub comment posted successfully", {
      previewRunId: args.previewRunId,
    });
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
    hasUiChanges: v.optional(v.boolean()),
    images: v.optional(
      v.array(
        v.object({
          storageId: v.string(),
          mimeType: v.string(),
          fileName: v.optional(v.string()),
          commitSha: v.string(),
          width: v.optional(v.number()),
          height: v.optional(v.number()),
          description: v.optional(v.string()),
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
    const runData = await ctx.runQuery(internal.previewRuns.getRunWithConfig, {
      previewRunId: args.previewRunId,
    });

    if (!runData?.run) {
      throw new Error("Preview run not found");
    }

    const { run: previewRun } = runData;

    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }

    // Verify the authenticated user is a member of the team that owns this preview run
    const { isMember } = await ctx.runQuery(internal.teams.checkTeamMembership, {
      teamId: previewRun.teamId,
      userId: identity.subject,
    });
    if (!isMember) {
      throw new Error("Forbidden: Not a member of this team");
    }

    const typedImages: Array<{
      storageId: Id<"_storage">;
      mimeType: string;
      fileName?: string;
      commitSha?: string;
      width?: number;
      height?: number;
      description?: string;
    }> = (args.images ?? []).map((img) => ({
      storageId: img.storageId as Id<"_storage">,
      mimeType: img.mimeType,
      fileName: img.fileName,
      commitSha: img.commitSha,
      width: img.width,
      height: img.height,
      description: img.description,
    }));

    const screenshotSetId = await ctx.runMutation(
      internal.previewScreenshots.createScreenshotSet,
      {
        previewRunId: args.previewRunId,
        status: args.status,
        commitSha: args.commitSha,
        error: args.error,
        hasUiChanges: args.hasUiChanges,
        images: typedImages,
      }
    );

    let githubCommentUrl: string | undefined;

    // Post GitHub comment for completed or skipped status
    if (
      previewRun.repoInstallationId &&
      screenshotSetId &&
      (args.status === "completed" || args.status === "skipped")
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
          internal.github_pr_comments.postPreviewComment,
          {
            installationId: previewRun.repoInstallationId,
            repoFullName: previewRun.repoFullName,
            prNumber: previewRun.prNumber,
            previewRunId: args.previewRunId,
            screenshotSetId,
          }
        );

        if (!commentResult?.ok) {
          throw new Error(
            commentResult.error ?? "Failed to post GitHub comment"
          );
        }

        if (commentResult.commentUrl) {
          githubCommentUrl = commentResult.commentUrl;
        }
      } catch (error) {
        console.error(
          "[previewScreenshots] Failed to post GitHub comment:",
          error
        );
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
