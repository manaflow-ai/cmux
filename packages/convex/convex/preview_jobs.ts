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
    });

    // Skip if this run was superseded by a newer commit
    if (payload.run.status === "superseded") {
      console.log("[preview-jobs] Preview run was superseded; skipping dispatch", {
        previewRunId: args.previewRunId,
        headSha: payload.run.headSha?.slice(0, 7),
        supersededBy: payload.run.supersededBy,
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

    // Note: We no longer block on other active runs for the same PR.
    // Each commit gets its own preview run. Older commits are marked as "superseded"
    // by enqueueFromWebhook when a new commit arrives, so they won't run.

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
