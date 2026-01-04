import {
  VideoRecordingStartPayloadSchema,
  VideoRecordingUploadPayloadSchema,
  VideoRecordingAddCheckpointPayloadSchema,
  VideoRecordingUploadUrlRequestSchema,
} from "@cmux/shared/convex-safe";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { httpAction } from "./_generated/server";
import { getWorkerAuth } from "./users/utils/getWorkerAuth";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

async function ensureJsonRequest(
  req: Request
): Promise<{ json: unknown } | Response> {
  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return jsonResponse(
      { code: 415, message: "Content-Type must be application/json" },
      415
    );
  }

  try {
    const json = await req.json();
    return { json };
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON body" }, 400);
  }
}

/**
 * Start a new video recording session for a task run.
 * Creates a recording record in "recording" status.
 */
export const startVideoRecording = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, { loggerPrefix: "[video-recordings]" });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = VideoRecordingStartPayloadSchema.safeParse(parsed.json);
  if (!validation.success) {
    console.warn(
      "[video-recordings] Invalid start recording payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const payload = validation.data;

  // Verify the task run exists and belongs to the authenticated user
  const run = await ctx.runQuery(internal.taskRuns.getById, {
    id: payload.runId as Id<"taskRuns">,
  });
  if (!run) {
    return jsonResponse({ code: 404, message: "Task run not found" }, 404);
  }

  if (
    run.teamId !== auth.payload.teamId ||
    run.userId !== auth.payload.userId ||
    run.taskId !== payload.taskId
  ) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  // Create the recording record
  const recordingId = await ctx.runMutation(
    internal.videoRecordings.startRecording,
    {
      taskId: payload.taskId as Id<"tasks">,
      runId: payload.runId as Id<"taskRuns">,
      userId: auth.payload.userId,
      teamId: auth.payload.teamId,
      commitSha: payload.commitSha,
    }
  );

  return jsonResponse({
    ok: true,
    recordingId,
  });
});

/**
 * Complete a video recording and upload the video file.
 * Updates the recording with the video storage ID and marks it as completed.
 */
export const uploadVideoRecording = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, { loggerPrefix: "[video-recordings]" });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = VideoRecordingUploadPayloadSchema.safeParse(parsed.json);
  if (!validation.success) {
    console.warn(
      "[video-recordings] Invalid upload payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const payload = validation.data;

  // Verify the recording exists and belongs to the authenticated user
  const recording = await ctx.runQuery(internal.videoRecordings.getById, {
    id: payload.recordingId as Id<"taskRunVideoRecordings">,
  });
  if (!recording) {
    return jsonResponse({ code: 404, message: "Recording not found" }, 404);
  }

  if (
    recording.teamId !== auth.payload.teamId ||
    recording.userId !== auth.payload.userId
  ) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  if (recording.status !== "recording" && recording.status !== "processing") {
    return jsonResponse(
      { code: 400, message: "Recording is not in a valid state for upload" },
      400
    );
  }

  // Complete the recording with the video file
  await ctx.runMutation(internal.videoRecordings.completeRecording, {
    recordingId: payload.recordingId as Id<"taskRunVideoRecordings">,
    storageId: payload.storageId as Id<"_storage">,
    durationMs: payload.durationMs,
    fileSizeBytes: payload.fileSizeBytes,
    checkpoints: payload.checkpoints ?? [],
  });

  return jsonResponse({
    ok: true,
    recordingId: payload.recordingId,
  });
});

/**
 * Add a checkpoint to an active recording.
 * Checkpoints mark significant moments in the video (commits, commands, etc.)
 */
export const addVideoCheckpoint = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, { loggerPrefix: "[video-recordings]" });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = VideoRecordingAddCheckpointPayloadSchema.safeParse(
    parsed.json
  );
  if (!validation.success) {
    console.warn(
      "[video-recordings] Invalid add checkpoint payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const payload = validation.data;

  // Verify the recording exists and belongs to the authenticated user
  const recording = await ctx.runQuery(internal.videoRecordings.getById, {
    id: payload.recordingId as Id<"taskRunVideoRecordings">,
  });
  if (!recording) {
    return jsonResponse({ code: 404, message: "Recording not found" }, 404);
  }

  if (
    recording.teamId !== auth.payload.teamId ||
    recording.userId !== auth.payload.userId
  ) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  if (recording.status !== "recording") {
    return jsonResponse(
      { code: 400, message: "Recording is not active" },
      400
    );
  }

  // Add the checkpoint
  await ctx.runMutation(internal.videoRecordings.addCheckpoint, {
    recordingId: payload.recordingId as Id<"taskRunVideoRecordings">,
    checkpoint: payload.checkpoint,
  });

  return jsonResponse({ ok: true });
});

/**
 * Generate an upload URL for a video file.
 */
export const createVideoUploadUrl = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, { loggerPrefix: "[video-recordings]" });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = VideoRecordingUploadUrlRequestSchema.safeParse(
    parsed.json
  );
  if (!validation.success) {
    console.warn(
      "[video-recordings] Invalid upload URL request payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  // Validate content type is a video format
  const { contentType } = validation.data;
  if (!contentType.startsWith("video/")) {
    return jsonResponse(
      { code: 400, message: "Content type must be a video format" },
      400
    );
  }

  const uploadUrl = await ctx.storage.generateUploadUrl();
  return jsonResponse({ ok: true, uploadUrl });
});

/**
 * Mark a recording as failed.
 */
export const failVideoRecording = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, { loggerPrefix: "[video-recordings]" });
  if (!auth) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const body = parsed.json as { recordingId?: string; error?: string };
  if (!body.recordingId) {
    return jsonResponse({ code: 400, message: "recordingId is required" }, 400);
  }

  // Verify the recording exists and belongs to the authenticated user
  const recording = await ctx.runQuery(internal.videoRecordings.getById, {
    id: body.recordingId as Id<"taskRunVideoRecordings">,
  });
  if (!recording) {
    return jsonResponse({ code: 404, message: "Recording not found" }, 404);
  }

  if (
    recording.teamId !== auth.payload.teamId ||
    recording.userId !== auth.payload.userId
  ) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  await ctx.runMutation(internal.videoRecordings.failRecording, {
    recordingId: body.recordingId as Id<"taskRunVideoRecordings">,
    error: body.error ?? "Recording failed",
  });

  return jsonResponse({ ok: true });
});
