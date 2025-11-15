import { createMorphCloudClient, stopInstanceInstanceInstanceIdDelete } from "@cmux/morphcloud-openapi-client";
import { env } from "../_shared/convex-env";
import { internal } from "./_generated/api";
import { httpAction, type ActionCtx } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import { runPreviewJob } from "./preview_jobs_worker";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function verifyAuth(req: Request): boolean {
  const authHeader = req.headers.get("authorization");
  if (!authHeader) return false;

  const [scheme, token] = authHeader.split(" ");
  if (scheme !== "Bearer") return false;

  return token === env.CMUX_TASK_RUN_JWT_SECRET;
}

async function stopPreviewInstance(
  ctx: ActionCtx,
  previewRun: Doc<"previewRuns">,
): Promise<void> {
  if (!previewRun?.morphInstanceId) {
    return;
  }
  if (previewRun.morphInstanceStoppedAt) {
    console.log("[preview-jobs-http] Morph instance already stopped", {
      previewRunId: previewRun._id,
      morphInstanceId: previewRun.morphInstanceId,
    });
    return;
  }
  const morphApiKey = env.MORPH_API_KEY;
  if (!morphApiKey) {
    console.warn("[preview-jobs-http] Cannot stop Morph instance without MORPH_API_KEY", {
      previewRunId: previewRun._id,
      morphInstanceId: previewRun.morphInstanceId,
    });
    return;
  }

  const morphClient = createMorphCloudClient({ auth: morphApiKey });
  const stoppedAt = Date.now();

  try {
    await stopInstanceInstanceInstanceIdDelete({
      client: morphClient,
      path: { instance_id: previewRun.morphInstanceId },
    });
    console.log("[preview-jobs-http] Stopped Morph instance for preview run", {
      previewRunId: previewRun._id,
      morphInstanceId: previewRun.morphInstanceId,
    });
  } catch (error) {
    console.error("[preview-jobs-http] Failed to stop Morph instance", {
      previewRunId: previewRun._id,
      morphInstanceId: previewRun.morphInstanceId,
      error,
    });
  }

  try {
    await ctx.runMutation(internal.previewRuns.updateInstanceMetadata, {
      previewRunId: previewRun._id,
      morphInstanceStoppedAt: stoppedAt,
    });
  } catch (error) {
    console.error("[preview-jobs-http] Failed to record Morph instance stop time", {
      previewRunId: previewRun._id,
      error,
    });
  }

  if (previewRun.taskRunId) {
    try {
      await ctx.runMutation(internal.taskRuns.updateVSCodeMetadataInternal, {
        taskRunId: previewRun.taskRunId,
        vscode: {
          provider: "morph",
          status: "stopped",
          containerName: previewRun.morphInstanceId,
          stoppedAt,
        },
        networking: [],
      });
    } catch (error) {
      console.error("[preview-jobs-http] Failed to update task run VSCode metadata after stop", {
        previewRunId: previewRun._id,
        taskRunId: previewRun.taskRunId,
        error,
      });
    }
  }
}

export const dispatchPreviewJob = httpAction(async (ctx, req) => {
  if (!verifyAuth(req)) {
    console.error("[preview-jobs-http] Unauthorized dispatch request");
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  let body: { previewRunId?: string };
  try {
    body = (await req.json()) as { previewRunId?: string };
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  if (!body.previewRunId) {
    return jsonResponse({ error: "previewRunId is required" }, 400);
  }

  const previewRunId = body.previewRunId as Id<"previewRuns">;
  console.log("[preview-jobs-http] Dispatching preview job", {
    previewRunId,
  });

  try {
    await ctx.runMutation(internal.previewRuns.markDispatched, {
      previewRunId,
    });
  } catch (error) {
    console.error("[preview-jobs-http] Failed to mark run dispatched", {
      previewRunId,
      error,
    });
    return jsonResponse({ error: "Failed to mark run dispatched" }, 500);
  }

  try {
    await runPreviewJob(ctx, previewRunId);
    return jsonResponse({ success: true }, 200);
  } catch (error) {
    console.error("[preview-jobs-http] Preview job execution failed", {
      previewRunId,
      error,
    });
    return jsonResponse(
      {
        error: "Failed to execute preview job",
        message:
          error instanceof Error ? error.message : String(error ?? "Unknown error"),
      },
      500,
    );
  }
});

/**
 * HTTP action for www API to update preview run status
 */
export const updatePreviewStatus = httpAction(async (ctx, req) => {
  if (!verifyAuth(req)) {
    console.error("[preview-jobs-http] Unauthorized request");
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  if (
    !body ||
    typeof body !== "object" ||
    !("previewRunId" in body) ||
    !("status" in body)
  ) {
    return jsonResponse({ error: "Missing required fields" }, 400);
  }

  const { previewRunId, status, stateReason, screenshotSetId } = body as {
    previewRunId: string;
    status: string;
    stateReason?: string;
    screenshotSetId?: string;
  };

  console.log("[preview-jobs-http] Updating preview run status", {
    previewRunId,
    status,
  });

  // Validate status
  if (!["running", "completed", "failed", "skipped"].includes(status)) {
    return jsonResponse({ error: "Invalid status value" }, 400);
  }

  try {
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId: previewRunId as Id<"previewRuns">,
      status: status as "running" | "completed" | "failed" | "skipped",
      stateReason,
      screenshotSetId: screenshotSetId as Id<"previewScreenshotSets"> | undefined,
    });

    return jsonResponse({ success: true });
  } catch (error) {
    console.error("[preview-jobs-http] Failed to update status", {
      previewRunId,
      error,
    });
    return jsonResponse({ error: "Failed to update status" }, 500);
  }
});

/**
 * HTTP action for www API to create screenshot set
 */
export const createScreenshotSet = httpAction(async (ctx, req) => {
  if (!verifyAuth(req)) {
    console.error("[preview-jobs-http] Unauthorized request");
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  if (
    !body ||
    typeof body !== "object" ||
    !("previewRunId" in body) ||
    !("status" in body) ||
    !("commitSha" in body)
  ) {
    return jsonResponse({ error: "Missing required fields" }, 400);
  }

  const { previewRunId, status, commitSha, error, images } = body as {
    previewRunId: string;
    status: string;
    commitSha: string;
    error?: string;
    images: Array<{
      storageId: string;
      mimeType: string;
      fileName?: string;
      commitSha?: string;
      width?: number;
      height?: number;
    }>;
  };

  console.log("[preview-jobs-http] Creating screenshot set", {
    previewRunId,
    status,
    imageCount: images?.length ?? 0,
  });

  // Validate status
  if (!["completed", "failed", "skipped"].includes(status)) {
    return jsonResponse({ error: "Invalid status value" }, 400);
  }

  try {
    const screenshotSetId = await ctx.runMutation(
      internal.previewScreenshots.createScreenshotSet,
      {
        previewRunId: previewRunId as Id<"previewRuns">,
        status: status as "completed" | "failed" | "skipped",
        commitSha,
        error,
        images: (images ?? []).map((img) => ({
          storageId: img.storageId as Id<"_storage">,
          mimeType: img.mimeType,
          fileName: img.fileName,
          commitSha: img.commitSha,
          width: img.width,
          height: img.height,
        })),
      }
    );

    return jsonResponse({ success: true, screenshotSetId });
  } catch (err) {
    console.error("[preview-jobs-http] Failed to create screenshot set", {
      previewRunId,
      error: err,
    });
    return jsonResponse({ error: "Failed to create screenshot set" }, 500);
  }
});

/**
 * HTTP action called by worker when preview job screenshots are complete
 * Copies screenshots from task run to preview run and posts GitHub comment
 */
export const completePreviewJob = httpAction(async (ctx, req) => {
  if (!verifyAuth(req)) {
    console.error("[preview-jobs-http] Unauthorized complete request");
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  if (
    !body ||
    typeof body !== "object" ||
    !("taskRunId" in body)
  ) {
    return jsonResponse({ error: "Missing taskRunId" }, 400);
  }

  const { taskRunId } = body as { taskRunId: string };

  console.log("[preview-jobs-http] Completing preview job", {
    taskRunId,
  });

  let previewRun: Doc<"previewRuns"> | null = null;
  let shouldStopInstance = false;

  try {
    // Find preview run by taskRunId
    previewRun = await ctx.runQuery(internal.previewRuns.getByTaskRunId, {
      taskRunId: taskRunId as Id<"taskRuns">,
    });

    if (!previewRun) {
      console.error("[preview-jobs-http] Preview run not found for task run", {
        taskRunId,
      });
      return jsonResponse({ error: "Preview run not found" }, 404);
    }
    shouldStopInstance = true;

    // Get task run to check for screenshots
    const taskRun = await ctx.runQuery(internal.taskRuns.getById, {
      id: taskRunId as Id<"taskRuns">,
    });

    if (!taskRun) {
      console.error("[preview-jobs-http] Task run not found", {
        taskRunId,
      });
      return jsonResponse({ error: "Task run not found" }, 404);
    }

    if (!taskRun.latestScreenshotSetId) {
      console.log("[preview-jobs-http] No screenshots found for task run", {
        taskRunId,
      });
      return jsonResponse({
        success: true,
        skipped: true,
        reason: "No screenshots available"
      });
    }

    // Get the task run screenshot set
    const taskScreenshotSet = await ctx.runQuery(
      internal.github_pr_queries.getScreenshotSet,
      {
        screenshotSetId: taskRun.latestScreenshotSetId,
      }
    );

    if (!taskScreenshotSet) {
      console.error("[preview-jobs-http] Screenshot set not found", {
        taskRunId,
        screenshotSetId: taskRun.latestScreenshotSetId,
      });
      return jsonResponse({ error: "Screenshot set not found" }, 404);
    }

    console.log("[preview-jobs-http] Found screenshot set for task run", {
      taskRunId,
      previewRunId: previewRun._id,
      screenshotSetId: taskRun.latestScreenshotSetId,
      imageCount: taskScreenshotSet.images.length,
    });

    // Post GitHub comment if we have installation ID
    if (previewRun.repoInstallationId) {
      const commentResult = await ctx.runAction(
        internal.github_pr_comments.postPreviewCommentWithTaskScreenshots,
        {
          installationId: previewRun.repoInstallationId,
          repoFullName: previewRun.repoFullName,
          prNumber: previewRun.prNumber,
          taskRunId: taskRunId as Id<"taskRuns">,
          previewRunId: previewRun._id,
        }
      );

      if (commentResult.ok) {
        console.log("[preview-jobs-http] Successfully posted GitHub comment", {
          taskRunId,
          previewRunId: previewRun._id,
          commentUrl: commentResult.commentUrl,
        });
        return jsonResponse({
          success: true,
          commentUrl: commentResult.commentUrl,
        });
      } else {
        console.error("[preview-jobs-http] Failed to post GitHub comment", {
          taskRunId,
          previewRunId: previewRun._id,
          error: commentResult.error,
        });
        return jsonResponse({
          success: false,
          error: `Failed to post GitHub comment: ${commentResult.error}`,
        }, 500);
      }
    } else {
      console.log("[preview-jobs-http] No GitHub installation ID, skipping comment", {
        taskRunId,
        previewRunId: previewRun._id,
      });

      // Update preview run status to completed even without posting comment
      await ctx.runMutation(internal.previewRuns.updateStatus, {
        previewRunId: previewRun._id,
        status: "completed",
      });

      return jsonResponse({
        success: true,
        skipped: true,
        reason: "No GitHub installation ID",
      });
    }
  } catch (error) {
    console.error("[preview-jobs-http] Failed to complete preview job", {
      taskRunId,
      error,
    });
    return jsonResponse({
      error: "Failed to complete preview job",
      message: error instanceof Error ? error.message : String(error),
    }, 500);
  } finally {
    if (shouldStopInstance && previewRun) {
      await stopPreviewInstance(ctx, previewRun);
    }
  }
});
