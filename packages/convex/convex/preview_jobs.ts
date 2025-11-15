import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";
import { runPreviewJob } from "./preview_jobs_worker";

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
