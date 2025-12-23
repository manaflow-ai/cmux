import {
  createMorphCloudClient,
  stopInstanceInstanceInstanceIdDelete,
} from "@cmux/morphcloud-openapi-client";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";
import { runPreviewJob } from "./preview_jobs_worker";

export const stopPreviewInstance = internalAction({
  args: {
    previewRunId: v.id("previewRuns"),
  },
  handler: async (ctx, { previewRunId }) => {
    const previewRun = await ctx.runQuery(internal.previewRuns.getById, { id: previewRunId });
    if (!previewRun) {
      console.warn("[preview-jobs] Preview run not found when stopping instance", {
        previewRunId,
      });
      return;
    }

    if (!previewRun.taskRunId) {
      console.warn("[preview-jobs] Preview run missing taskRunId, cannot stop instance", {
        previewRunId: previewRun._id,
      });
      return;
    }

    const taskRun = await ctx.runQuery(internal.taskRuns.getById, {
      id: previewRun.taskRunId,
    });

    const containerName = taskRun?.vscode?.containerName;
    const provider = taskRun?.vscode?.provider ?? "morph";

    if (!taskRun || !containerName) {
      console.warn("[preview-jobs] Task run missing Morph container info", {
        previewRunId: previewRun._id,
        taskRunId: previewRun.taskRunId,
      });
      return;
    }

    const morphApiKey = process.env.MORPH_API_KEY;
    if (!morphApiKey) {
      console.warn(
        "[preview-jobs] Cannot stop Morph instance without MORPH_API_KEY",
        {
          previewRunId: previewRun._id,
          taskRunId: taskRun._id,
        }
      );
      return;
    }

    const morphClient = createMorphCloudClient({ auth: morphApiKey });
    const stoppedAt = Date.now();

    try {
      await stopInstanceInstanceInstanceIdDelete({
        client: morphClient,
        path: { instance_id: containerName },
      });
    } catch (error) {
      console.error("[preview-jobs] Failed to stop Morph instance", {
        previewRunId: previewRun._id,
        taskRunId: taskRun._id,
        containerName,
        error,
      });
    }

    try {
      await ctx.runMutation(internal.taskRuns.updateVSCodeMetadataInternal, {
        taskRunId: taskRun._id,
        vscode: {
          provider,
          status: "stopped",
          containerName,
          stoppedAt,
        },
        networking: [],
      });
    } catch (error) {
      console.error(
        "[preview-jobs] Failed to update task run VSCode metadata after stop",
        {
          previewRunId: previewRun._id,
          taskRunId: taskRun._id,
          containerName,
          error,
        }
      );
    }
  },
});

export const requestDispatch = internalAction({
  args: {
    previewRunId: v.id("previewRuns"),
  },
  handler: async (ctx, args) => {
    console.log("[preview-jobs] Starting dispatch process", {
      previewRunId: args.previewRunId,
    });

    const payload = await ctx.runQuery(internal.previewRuns.getRunWithConfig, {
      previewRunId: args.previewRunId,
    });

    if (!payload?.run || !payload.config) {
      console.warn("[preview-jobs] Missing run/config for dispatch", args);
      return;
    }

    console.log("[preview-jobs] Preview run details", {
      previewRunId: args.previewRunId,
      repoFullName: payload.run.repoFullName,
      prNumber: payload.run.prNumber,
      headSha: payload.run.headSha?.slice(0, 7),
      status: payload.run.status,
      taskRunId: payload.run.taskRunId,
    });

    // Check if there's already an active preview run for this PR
    // Skip dispatch if another run is already running (prevents duplicate jobs)
    const activeRun = await ctx.runQuery(internal.previewRuns.getActiveByConfigAndPr, {
      previewConfigId: payload.config._id,
      prNumber: payload.run.prNumber,
    });

    if (activeRun && activeRun._id !== args.previewRunId) {
      console.log("[preview-jobs] Another preview run is already active for this PR; skipping dispatch", {
        previewRunId: args.previewRunId,
        activeRunId: activeRun._id,
        activeStatus: activeRun.status,
        prNumber: payload.run.prNumber,
      });
      return;
    }

    // Also skip if this specific run is not pending (e.g., already running or completed)
    if (payload.run.status !== "pending") {
      console.log("[preview-jobs] Preview run is not pending; skipping dispatch", {
        previewRunId: args.previewRunId,
        status: payload.run.status,
      });
      return;
    }

    // Check if the linked task run already has screenshots collected
    // If so, skip the full preview job and just post the GitHub comment
    if (payload.run.taskRunId) {
      const taskRun = await ctx.runQuery(internal.taskRuns.getById, {
        id: payload.run.taskRunId,
      });

      if (taskRun?.latestScreenshotSetId) {
        console.log("[preview-jobs] Task run already has screenshots, using fast path", {
          previewRunId: args.previewRunId,
          taskRunId: payload.run.taskRunId,
          screenshotSetId: taskRun.latestScreenshotSetId,
        });

        try {
          await ctx.runMutation(internal.previewRuns.markDispatched, {
            previewRunId: args.previewRunId,
          });

          // Post GitHub comment with existing screenshots (skip screenshot collection)
          await ctx.scheduler.runAfter(
            0,
            internal.preview_jobs.postExistingScreenshots,
            {
              previewRunId: args.previewRunId,
              taskRunId: payload.run.taskRunId,
              screenshotSetId: taskRun.latestScreenshotSetId,
            },
          );

          console.log("[preview-jobs] Scheduled fast path for existing screenshots", {
            previewRunId: args.previewRunId,
            taskRunId: payload.run.taskRunId,
          });
          return;
        } catch (error) {
          console.error("[preview-jobs] Failed to schedule fast path", {
            previewRunId: args.previewRunId,
            error,
          });
          // Fall through to regular dispatch
        }
      }
    }

    try {
      await ctx.runMutation(internal.previewRuns.markDispatched, {
        previewRunId: args.previewRunId,
      });
      console.log("[preview-jobs] Marked as dispatched", {
        previewRunId: args.previewRunId,
      });
    } catch (error) {
      console.error("[preview-jobs] Failed to mark preview run dispatched", {
        previewRunId: args.previewRunId,
        error,
      });
      return;
    }

    console.log("[preview-jobs] Scheduling preview job execution", {
      previewRunId: args.previewRunId,
    });

    try {
      await ctx.scheduler.runAfter(
        0,
        internal.preview_jobs.executePreviewJob,
        {
          previewRunId: args.previewRunId,
        },
      );
      console.log("[preview-jobs] Preview job scheduled", {
        previewRunId: args.previewRunId,
      });
    } catch (error) {
      console.error("[preview-jobs] Failed to schedule preview job", {
        previewRunId: args.previewRunId,
        error,
      });
    }
  },
});

export const executePreviewJob = internalAction({
  args: {
    previewRunId: v.id("previewRuns"),
  },
  handler: async (ctx, args) => {
    await runPreviewJob(ctx, args.previewRunId);
  },
});

/**
 * Fast path for posting GitHub comment when screenshots already exist.
 *
 * This is called when a task is created from cmux (not a preview job) and
 * screenshots were already collected via the cmux screenshot collector.
 * In this case, we skip the full preview job (no Morph instance, no screenshot
 * collection) and directly post the GitHub comment with existing screenshots.
 */
export const postExistingScreenshots = internalAction({
  args: {
    previewRunId: v.id("previewRuns"),
    taskRunId: v.id("taskRuns"),
    screenshotSetId: v.id("taskRunScreenshotSets"),
  },
  handler: async (ctx, args) => {
    const { previewRunId, taskRunId, screenshotSetId } = args;

    console.log("[preview-jobs] postExistingScreenshots: Starting fast path", {
      previewRunId,
      taskRunId,
      screenshotSetId,
    });

    // Get the preview run and config
    const payload = await ctx.runQuery(internal.previewRuns.getRunWithConfig, {
      previewRunId,
    });

    if (!payload?.run || !payload.config) {
      console.error("[preview-jobs] postExistingScreenshots: Missing run/config", {
        previewRunId,
      });
      await ctx.runMutation(internal.previewRuns.updateStatus, {
        previewRunId,
        status: "failed",
      });
      return;
    }

    const { run } = payload;

    // Verify the screenshot set exists
    const screenshotSet = await ctx.runQuery(
      internal.github_pr_queries.getScreenshotSet,
      { screenshotSetId }
    );

    if (!screenshotSet) {
      console.error("[preview-jobs] postExistingScreenshots: Screenshot set not found", {
        previewRunId,
        screenshotSetId,
      });
      await ctx.runMutation(internal.previewRuns.updateStatus, {
        previewRunId,
        status: "failed",
      });
      return;
    }

    console.log("[preview-jobs] postExistingScreenshots: Found screenshot set", {
      previewRunId,
      screenshotSetId,
      imageCount: screenshotSet.images.length,
      status: screenshotSet.status,
    });

    // Post GitHub comment if we have installation ID
    if (run.repoInstallationId) {
      const taskRun = await ctx.runQuery(internal.taskRuns.getById, {
        id: taskRunId,
      });

      if (!taskRun) {
        console.error("[preview-jobs] postExistingScreenshots: Task run not found", {
          previewRunId,
          taskRunId,
        });
        await ctx.runMutation(internal.previewRuns.updateStatus, {
          previewRunId,
          status: "failed",
        });
        return;
      }

      const team = await ctx.runQuery(internal.teams.getByTeamIdInternal, {
        teamId: taskRun.teamId,
      });
      const teamSlug = team?.slug ?? taskRun.teamId;
      const workspaceUrl = `https://www.cmux.sh/${teamSlug}/task/${taskRun.taskId}`;
      const devServerUrl = `https://www.cmux.sh/${teamSlug}/task/${taskRun.taskId}/run/${taskRunId}/browser`;

      const commentResult = await ctx.runAction(
        internal.github_pr_comments.postPreviewComment,
        {
          installationId: run.repoInstallationId,
          repoFullName: run.repoFullName,
          prNumber: run.prNumber,
          screenshotSetId,
          previewRunId,
          workspaceUrl,
          devServerUrl,
        }
      );

      if (commentResult.ok) {
        console.log("[preview-jobs] postExistingScreenshots: Successfully posted GitHub comment", {
          previewRunId,
          taskRunId,
          commentUrl: commentResult.commentUrl,
        });

        // Mark task as completed since we're done
        const task = await ctx.runQuery(internal.tasks.getByIdInternal, {
          id: taskRun.taskId,
        });

        if (task && !task.isCompleted) {
          await ctx.runMutation(internal.tasks.setCompletedInternal, {
            taskId: task._id,
            isCompleted: true,
            crownEvaluationStatus: "succeeded",
          });
        }

        // Mark task run as completed if not already
        if (taskRun.status !== "completed" && taskRun.status !== "failed") {
          await ctx.runMutation(internal.taskRuns.updateStatus, {
            id: taskRunId,
            status: "completed",
          });
        }

        return;
      } else {
        console.error("[preview-jobs] postExistingScreenshots: Failed to post GitHub comment", {
          previewRunId,
          taskRunId,
          error: commentResult.error,
        });
        await ctx.runMutation(internal.previewRuns.updateStatus, {
          previewRunId,
          status: "failed",
        });
        return;
      }
    } else {
      // No GitHub installation ID - just mark as completed
      console.log("[preview-jobs] postExistingScreenshots: No GitHub installation ID, marking completed", {
        previewRunId,
        taskRunId,
      });

      await ctx.runMutation(internal.previewRuns.updateStatus, {
        previewRunId,
        status: "completed",
        screenshotSetId,
      });

      return;
    }
  },
});
