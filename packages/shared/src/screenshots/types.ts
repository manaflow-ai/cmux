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
export const PreviewScreenshotStoredImageSchema = z.object({
  storageId: z.string(),
  mimeType: z.string(),
  fileName: z.string().optional(),
  commitSha: z.string(),
  width: z.number().optional(),
  height: z.number().optional(),
});
export type PreviewScreenshotStoredImage = z.infer<
  typeof PreviewScreenshotStoredImageSchema
>;

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
  screenshotSetId: typedZid("previewScreenshotSets").optional(),
});
export type PreviewScreenshotUploadResponse = z.infer<
  typeof PreviewScreenshotUploadResponseSchema
>;
