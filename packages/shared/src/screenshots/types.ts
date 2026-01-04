import { z } from "zod";
import { typedZid } from "../utils/typed-zid";

export const ScreenshotCollectionStatusSchema = z.enum([
  "pending",
  "running",
  "completed",
  "failed",
  "skipped",
]);
export type ScreenshotCollectionStatus = z.infer<
  typeof ScreenshotCollectionStatusSchema
>;

// Video recording types
export const VideoRecordingStatusSchema = z.enum([
  "recording",
  "processing",
  "completed",
  "failed",
]);
export type VideoRecordingStatus = z.infer<typeof VideoRecordingStatusSchema>;

export const VideoCheckpointTypeSchema = z.enum([
  "commit",
  "command",
  "file_change",
  "error",
  "milestone",
  "manual",
]);
export type VideoCheckpointType = z.infer<typeof VideoCheckpointTypeSchema>;

export const VideoCheckpointSchema = z.object({
  timestampMs: z.number(), // Position in video (milliseconds)
  label: z.string(), // Short label, e.g., "Installing dependencies"
  description: z.string().optional(), // Longer description
  type: VideoCheckpointTypeSchema.optional(),
});
export type VideoCheckpoint = z.infer<typeof VideoCheckpointSchema>;

export const ScreenshotStoredImageSchema = z.object({
  storageId: z.string(),
  mimeType: z.string(),
  fileName: z.string().optional(),
  commitSha: z.string(),
  description: z.string().optional(),
});
export type ScreenshotStoredImage = z.infer<
  typeof ScreenshotStoredImageSchema
>;

export const ScreenshotUploadPayloadSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
  status: z.enum(["completed", "failed", "skipped"]),
  /** Required for completed status, optional for failed/skipped */
  commitSha: z.string().optional(),
  images: z.array(ScreenshotStoredImageSchema).optional(),
  error: z.string().optional(),
  hasUiChanges: z.boolean().optional(),
});
export type ScreenshotUploadPayload = z.infer<
  typeof ScreenshotUploadPayloadSchema
>;

export const ScreenshotUploadResponseSchema = z.object({
  ok: z.literal(true),
  storageIds: z.array(z.string()).optional(),
  screenshotSetId: typedZid("taskRunScreenshotSets").optional(),
});
export type ScreenshotUploadResponse = z.infer<
  typeof ScreenshotUploadResponseSchema
>;

export const ScreenshotUploadUrlRequestSchema = z.object({
  contentType: z.string(),
});
export type ScreenshotUploadUrlRequest = z.infer<
  typeof ScreenshotUploadUrlRequestSchema
>;

export const ScreenshotUploadUrlResponseSchema = z.object({
  ok: z.literal(true),
  uploadUrl: z.string(),
});
export type ScreenshotUploadUrlResponse = z.infer<
  typeof ScreenshotUploadUrlResponseSchema
>;

// Preview screenshot schemas
export const PreviewScreenshotStoredImageSchema = ScreenshotStoredImageSchema;
export type PreviewScreenshotStoredImage = ScreenshotStoredImage;

export const PreviewScreenshotUploadPayloadSchema = z.object({
  previewRunId: typedZid("previewRuns"),
  status: z.enum(["completed", "failed", "skipped"]),
  images: z.array(PreviewScreenshotStoredImageSchema).optional(),
  error: z.string().optional(),
  commitSha: z.string(),
});
export type PreviewScreenshotUploadPayload = z.infer<
  typeof PreviewScreenshotUploadPayloadSchema
>;

export const PreviewScreenshotUploadResponseSchema = z.object({
  ok: z.literal(true),
  storageIds: z.array(z.string()).optional(),
  screenshotSetId: typedZid("taskRunScreenshotSets").optional(),
});
export type PreviewScreenshotUploadResponse = z.infer<
  typeof PreviewScreenshotUploadResponseSchema
>;

// Video recording upload schemas
export const VideoRecordingStartPayloadSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
  commitSha: z.string().optional(),
});
export type VideoRecordingStartPayload = z.infer<
  typeof VideoRecordingStartPayloadSchema
>;

export const VideoRecordingStartResponseSchema = z.object({
  ok: z.literal(true),
  recordingId: typedZid("taskRunVideoRecordings"),
});
export type VideoRecordingStartResponse = z.infer<
  typeof VideoRecordingStartResponseSchema
>;

export const VideoRecordingUploadPayloadSchema = z.object({
  recordingId: typedZid("taskRunVideoRecordings"),
  storageId: z.string(),
  durationMs: z.number(),
  fileSizeBytes: z.number().optional(),
  checkpoints: z.array(VideoCheckpointSchema).optional(),
});
export type VideoRecordingUploadPayload = z.infer<
  typeof VideoRecordingUploadPayloadSchema
>;

export const VideoRecordingUploadResponseSchema = z.object({
  ok: z.literal(true),
  recordingId: typedZid("taskRunVideoRecordings"),
});
export type VideoRecordingUploadResponse = z.infer<
  typeof VideoRecordingUploadResponseSchema
>;

export const VideoRecordingAddCheckpointPayloadSchema = z.object({
  recordingId: typedZid("taskRunVideoRecordings"),
  checkpoint: VideoCheckpointSchema,
});
export type VideoRecordingAddCheckpointPayload = z.infer<
  typeof VideoRecordingAddCheckpointPayloadSchema
>;

export const VideoRecordingAddCheckpointResponseSchema = z.object({
  ok: z.literal(true),
});
export type VideoRecordingAddCheckpointResponse = z.infer<
  typeof VideoRecordingAddCheckpointResponseSchema
>;

export const VideoRecordingUploadUrlRequestSchema = z.object({
  contentType: z.string(), // Should be "video/webm" or similar
});
export type VideoRecordingUploadUrlRequest = z.infer<
  typeof VideoRecordingUploadUrlRequestSchema
>;

export const VideoRecordingUploadUrlResponseSchema = z.object({
  ok: z.literal(true),
  uploadUrl: z.string(),
});
export type VideoRecordingUploadUrlResponse = z.infer<
  typeof VideoRecordingUploadUrlResponseSchema
>;
