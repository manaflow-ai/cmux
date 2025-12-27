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

/**
 * Cancels all running/pending preview runs for a PR except the specified one.
 * This is called when a new commit is pushed to ensure only the latest commit's preview runs.
 *
 * For each cancelled run:
 * 1. Stops the Morph instance (if running)
 * 2. Posts/updates GitHub comment with cancellation notice
 * 3. Marks the run as "superseded"
 */
export const cancelPreviousPreviewsForPr = internalAction({
  args: {
    previewConfigId: v.id("previewConfigs"),
    prNumber: v.number(),
    newHeadSha: v.string(),
    exceptRunId: v.id("previewRuns"),
    installationId: v.optional(v.number()),
    repoFullName: v.string(),
  },
  handler: async (ctx, args) => {
    const { previewConfigId, prNumber, newHeadSha, exceptRunId, installationId, repoFullName } = args;

    // Get all active runs for this PR
    const runs = await ctx.runQuery(internal.previewRuns.listByConfigAndPr, {
      previewConfigId,
      prNumber,
      limit: 20,
    });

    const runsToCancel = runs.filter(
      (r) => r._id !== exceptRunId && (r.status === "pending" || r.status === "running"),
    );

    if (runsToCancel.length === 0) {
      console.log("[preview-jobs] No runs to cancel for PR", {
        previewConfigId,
        prNumber,
        newHeadSha: newHeadSha.slice(0, 7),
      });
      return { cancelledCount: 0 };
    }

    console.log("[preview-jobs] Cancelling previous preview runs for PR", {
      previewConfigId,
      prNumber,
      newHeadSha: newHeadSha.slice(0, 7),
      runsToCancel: runsToCancel.map((r) => ({
        id: r._id,
        headSha: r.headSha.slice(0, 7),
        status: r.status,
      })),
    });

    let cancelledCount = 0;

    for (const run of runsToCancel) {
      try {
        // Step 1: Stop the Morph instance if the run is actively running
        if (run.status === "running" && run.taskRunId) {
          try {
            await ctx.runAction(internal.preview_jobs.stopPreviewInstance, {
              previewRunId: run._id,
            });
            console.log("[preview-jobs] Stopped Morph instance for cancelled run", {
              previewRunId: run._id,
              headSha: run.headSha.slice(0, 7),
            });
          } catch (stopError) {
            console.error("[preview-jobs] Failed to stop Morph instance for cancelled run", {
              previewRunId: run._id,
              error: stopError instanceof Error ? stopError.message : String(stopError),
            });
            // Continue with cancellation even if stop fails
          }
        }

        // Step 2: Post/update GitHub comment with cancellation notice
        if (installationId) {
          try {
            await ctx.runAction(internal.github_pr_comments.postCancellationComment, {
              installationId,
              repoFullName,
              prNumber,
              previewRunId: run._id,
              cancelledHeadSha: run.headSha,
              newHeadSha,
              existingCommentId: run.githubCommentId,
            });
          } catch (commentError) {
            console.error("[preview-jobs] Failed to post cancellation comment", {
              previewRunId: run._id,
              error: commentError instanceof Error ? commentError.message : String(commentError),
            });
            // Continue with cancellation even if comment fails
          }
        }

        // Step 3: Mark the run as superseded
        await ctx.runMutation(internal.previewRuns.updateStatus, {
          previewRunId: run._id,
          status: "superseded",
        });

        // Also mark any associated task run as cancelled
        if (run.taskRunId) {
          try {
            await ctx.runMutation(internal.taskRuns.updateStatus, {
              id: run.taskRunId,
              status: "cancelled",
            });
          } catch (taskRunError) {
            console.error("[preview-jobs] Failed to mark task run as cancelled", {
              previewRunId: run._id,
              taskRunId: run.taskRunId,
              error: taskRunError instanceof Error ? taskRunError.message : String(taskRunError),
            });
          }
        }

        cancelledCount++;
        console.log("[preview-jobs] Cancelled preview run", {
          previewRunId: run._id,
          headSha: run.headSha.slice(0, 7),
          previousStatus: run.status,
        });
      } catch (error) {
        console.error("[preview-jobs] Failed to cancel preview run", {
          previewRunId: run._id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    console.log("[preview-jobs] Finished cancelling previous preview runs", {
      previewConfigId,
      prNumber,
      newHeadSha: newHeadSha.slice(0, 7),
      cancelledCount,
      totalAttempted: runsToCancel.length,
    });

    return { cancelledCount };
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
    });

    // Skip if this run was superseded by a newer commit
    if (payload.run.status === "superseded") {
      console.log("[preview-jobs] Preview run was superseded by newer commit; skipping dispatch", {
        previewRunId: args.previewRunId,
        headSha: payload.run.headSha?.slice(0, 7),
        stateReason: payload.run.stateReason,
      });
      return;
    }

    // Skip if this specific run is not pending (e.g., already running or completed)
    if (payload.run.status !== "pending") {
      console.log("[preview-jobs] Preview run is not pending; skipping dispatch", {
        previewRunId: args.previewRunId,
        status: payload.run.status,
      });
      return;
    }

    // Note: We no longer wait for running jobs - cancelPreviousPreviewsForPr handles stopping them
    // This dispatch should proceed immediately since the caller already cancelled previous runs

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
