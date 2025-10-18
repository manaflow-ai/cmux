import { z } from "zod";

export const codeReviewCallbackSuccessSchema = z.object({
  status: z.literal("success"),
  jobId: z.string(),
  sandboxInstanceId: z.string(),
  codeReviewOutput: z.record(z.string(), z.any()),
});

export const codeReviewCallbackErrorSchema = z.object({
  status: z.literal("error"),
  jobId: z.string(),
  sandboxInstanceId: z.string().optional(),
  errorCode: z.string().optional(),
  errorDetail: z.string().optional(),
});

export const codeReviewCallbackSchema = z.union([
  codeReviewCallbackSuccessSchema,
  codeReviewCallbackErrorSchema,
]);

export type CodeReviewCallbackPayload = z.infer<typeof codeReviewCallbackSchema>;

export const codeReviewFileCallbackSchema = z.object({
  jobId: z.string(),
  sandboxInstanceId: z.string().optional(),
  filePath: z.string(),
  commitRef: z.string().optional(),
  codexReviewOutput: z.any(),
});

export type CodeReviewFileCallbackPayload = z.infer<
  typeof codeReviewFileCallbackSchema
>;
