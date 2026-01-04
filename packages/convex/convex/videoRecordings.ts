import { v } from "convex/values";
import { internalMutation, internalQuery, mutation, query } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Id, Doc } from "./_generated/dataModel";

// Internal query to get a video recording by ID
export const getById = internalQuery({
  args: {
    id: v.id("taskRunVideoRecordings"),
  },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.id);
  },
});

// Public query to get video recordings for a task run
export const getByRunId = query({
  args: {
    runId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const recordings = await ctx.db
      .query("taskRunVideoRecordings")
      .withIndex("by_run", (q) => q.eq("runId", args.runId))
      .order("desc")
      .collect();

    // Add video URLs for completed recordings
    return Promise.all(
      recordings.map(async (recording) => {
        let videoUrl: string | null = null;
        if (recording.storageId && recording.status === "completed") {
          videoUrl = await ctx.storage.getUrl(recording.storageId);
        }
        return { ...recording, videoUrl };
      })
    );
  },
});

// Public query to get video recordings for a task
export const getByTaskId = query({
  args: {
    taskId: v.id("tasks"),
  },
  handler: async (ctx, args) => {
    const recordings = await ctx.db
      .query("taskRunVideoRecordings")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .order("desc")
      .collect();

    // Add video URLs for completed recordings
    return Promise.all(
      recordings.map(async (recording) => {
        let videoUrl: string | null = null;
        if (recording.storageId && recording.status === "completed") {
          videoUrl = await ctx.storage.getUrl(recording.storageId);
        }
        return { ...recording, videoUrl };
      })
    );
  },
});

// Start a new video recording
export const startRecording = internalMutation({
  args: {
    taskId: v.id("tasks"),
    runId: v.id("taskRuns"),
    userId: v.string(),
    teamId: v.string(),
    commitSha: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();

    const recordingId = await ctx.db.insert("taskRunVideoRecordings", {
      taskId: args.taskId,
      runId: args.runId,
      mimeType: "video/webm",
      checkpoints: [],
      status: "recording",
      recordingStartedAt: now,
      commitSha: args.commitSha,
      userId: args.userId,
      teamId: args.teamId,
      createdAt: now,
      updatedAt: now,
    });

    // Update the task run with the recording reference
    await ctx.db.patch(args.runId, {
      latestVideoRecordingId: recordingId,
    });

    return recordingId;
  },
});

// Complete a recording with the video file
export const completeRecording = internalMutation({
  args: {
    recordingId: v.id("taskRunVideoRecordings"),
    storageId: v.id("_storage"),
    durationMs: v.number(),
    fileSizeBytes: v.optional(v.number()),
    checkpoints: v.array(
      v.object({
        timestampMs: v.number(),
        label: v.string(),
        description: v.optional(v.string()),
        type: v.optional(
          v.union(
            v.literal("commit"),
            v.literal("command"),
            v.literal("file_change"),
            v.literal("error"),
            v.literal("milestone"),
            v.literal("manual")
          )
        ),
      })
    ),
  },
  handler: async (ctx, args) => {
    const now = Date.now();

    const recording = await ctx.db.get(args.recordingId);
    if (!recording) {
      throw new Error("Recording not found");
    }

    // Merge existing checkpoints with new ones, sorted by timestamp
    const allCheckpoints = [...recording.checkpoints, ...args.checkpoints].sort(
      (a, b) => a.timestampMs - b.timestampMs
    );

    await ctx.db.patch(args.recordingId, {
      storageId: args.storageId,
      durationMs: args.durationMs,
      fileSizeBytes: args.fileSizeBytes,
      checkpoints: allCheckpoints,
      status: "completed",
      recordingCompletedAt: now,
      updatedAt: now,
    });
  },
});

// Add a checkpoint to an active recording
export const addCheckpoint = internalMutation({
  args: {
    recordingId: v.id("taskRunVideoRecordings"),
    checkpoint: v.object({
      timestampMs: v.number(),
      label: v.string(),
      description: v.optional(v.string()),
      type: v.optional(
        v.union(
          v.literal("commit"),
          v.literal("command"),
          v.literal("file_change"),
          v.literal("error"),
          v.literal("milestone"),
          v.literal("manual")
        )
      ),
    }),
  },
  handler: async (ctx, args) => {
    const recording = await ctx.db.get(args.recordingId);
    if (!recording) {
      throw new Error("Recording not found");
    }

    // Add the new checkpoint and keep sorted by timestamp
    const checkpoints = [...recording.checkpoints, args.checkpoint].sort(
      (a, b) => a.timestampMs - b.timestampMs
    );

    await ctx.db.patch(args.recordingId, {
      checkpoints,
      updatedAt: Date.now(),
    });
  },
});

// Mark a recording as failed
export const failRecording = internalMutation({
  args: {
    recordingId: v.id("taskRunVideoRecordings"),
    error: v.string(),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.recordingId, {
      status: "failed",
      error: args.error,
      recordingCompletedAt: Date.now(),
      updatedAt: Date.now(),
    });
  },
});

// Get the latest completed recording for a run (for display)
export const getLatestCompletedByRunId = query({
  args: {
    runId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const recording = await ctx.db
      .query("taskRunVideoRecordings")
      .withIndex("by_run", (q) => q.eq("runId", args.runId))
      .filter((q) => q.eq(q.field("status"), "completed"))
      .order("desc")
      .first();

    if (!recording || !recording.storageId) {
      return null;
    }

    const videoUrl = await ctx.storage.getUrl(recording.storageId);
    return { ...recording, videoUrl };
  },
});

// ============================================================================
// Client-accessible mutations (for browser-side recording via useVncRecorder)
// ============================================================================

/**
 * Start a new video recording from the browser.
 * Called when the user starts recording in the VNC viewer.
 */
export const clientStartRecording = mutation({
  args: {
    teamSlugOrId: v.string(),
    taskId: v.id("tasks"),
    runId: v.id("taskRuns"),
    commitSha: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }

    // Get team from slug or ID
    let team: Doc<"teams"> | null = null;
    team = await ctx.db
      .query("teams")
      .withIndex("by_slug", (q) => q.eq("slug", args.teamSlugOrId))
      .first();
    if (!team) {
      team = await ctx.db.get(args.teamSlugOrId as Id<"teams">);
    }
    if (!team) {
      throw new Error("Team not found");
    }

    // Verify user is a member of the team
    const { isMember } = await ctx.runQuery(internal.teams.checkTeamMembership, {
      teamId: team._id,
      userId: identity.subject,
    });
    if (!isMember) {
      throw new Error("Forbidden: Not a member of this team");
    }

    // Verify the task run exists and belongs to this team
    const run = await ctx.db.get(args.runId);
    if (!run || run.teamId !== team._id || run.taskId !== args.taskId) {
      throw new Error("Task run not found or access denied");
    }

    const now = Date.now();

    const recordingId = await ctx.db.insert("taskRunVideoRecordings", {
      taskId: args.taskId,
      runId: args.runId,
      mimeType: "video/webm",
      checkpoints: [],
      status: "recording",
      recordingStartedAt: now,
      commitSha: args.commitSha,
      userId: identity.subject,
      teamId: team._id,
      createdAt: now,
      updatedAt: now,
    });

    // Update the task run with the recording reference
    await ctx.db.patch(args.runId, {
      latestVideoRecordingId: recordingId,
    });

    return recordingId;
  },
});

/**
 * Generate an upload URL for the video recording blob.
 */
export const generateVideoUploadUrl = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }

    return await ctx.storage.generateUploadUrl();
  },
});

/**
 * Complete a video recording with the uploaded file.
 * Called after the video blob has been uploaded to storage.
 */
export const clientCompleteRecording = mutation({
  args: {
    recordingId: v.id("taskRunVideoRecordings"),
    storageId: v.id("_storage"),
    durationMs: v.number(),
    fileSizeBytes: v.optional(v.number()),
    checkpoints: v.array(
      v.object({
        timestampMs: v.number(),
        label: v.string(),
        description: v.optional(v.string()),
        type: v.optional(
          v.union(
            v.literal("commit"),
            v.literal("command"),
            v.literal("file_change"),
            v.literal("error"),
            v.literal("milestone"),
            v.literal("manual")
          )
        ),
      })
    ),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }

    const recording = await ctx.db.get(args.recordingId);
    if (!recording) {
      throw new Error("Recording not found");
    }

    // Verify the user owns this recording
    if (recording.userId !== identity.subject) {
      throw new Error("Not authorized to complete this recording");
    }

    if (recording.status !== "recording" && recording.status !== "processing") {
      throw new Error("Recording is not in a valid state for completion");
    }

    const now = Date.now();

    // Merge existing checkpoints with new ones, sorted by timestamp
    const allCheckpoints = [...recording.checkpoints, ...args.checkpoints].sort(
      (a, b) => a.timestampMs - b.timestampMs
    );

    await ctx.db.patch(args.recordingId, {
      storageId: args.storageId,
      durationMs: args.durationMs,
      fileSizeBytes: args.fileSizeBytes,
      checkpoints: allCheckpoints,
      status: "completed",
      recordingCompletedAt: now,
      updatedAt: now,
    });
  },
});

/**
 * Add a checkpoint to an active recording from the browser.
 */
export const clientAddCheckpoint = mutation({
  args: {
    recordingId: v.id("taskRunVideoRecordings"),
    checkpoint: v.object({
      timestampMs: v.number(),
      label: v.string(),
      description: v.optional(v.string()),
      type: v.optional(
        v.union(
          v.literal("commit"),
          v.literal("command"),
          v.literal("file_change"),
          v.literal("error"),
          v.literal("milestone"),
          v.literal("manual")
        )
      ),
    }),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }

    const recording = await ctx.db.get(args.recordingId);
    if (!recording) {
      throw new Error("Recording not found");
    }

    // Verify the user owns this recording
    if (recording.userId !== identity.subject) {
      throw new Error("Not authorized to modify this recording");
    }

    if (recording.status !== "recording") {
      throw new Error("Recording is not active");
    }

    // Add the new checkpoint and keep sorted by timestamp
    const checkpoints = [...recording.checkpoints, args.checkpoint].sort(
      (a, b) => a.timestampMs - b.timestampMs
    );

    await ctx.db.patch(args.recordingId, {
      checkpoints,
      updatedAt: Date.now(),
    });
  },
});

/**
 * Mark a client recording as failed.
 */
export const clientFailRecording = mutation({
  args: {
    recordingId: v.id("taskRunVideoRecordings"),
    error: v.string(),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }

    const recording = await ctx.db.get(args.recordingId);
    if (!recording) {
      throw new Error("Recording not found");
    }

    // Verify the user owns this recording
    if (recording.userId !== identity.subject) {
      throw new Error("Not authorized to modify this recording");
    }

    await ctx.db.patch(args.recordingId, {
      status: "failed",
      error: args.error,
      recordingCompletedAt: Date.now(),
      updatedAt: Date.now(),
    });
  },
});
