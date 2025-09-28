import { z } from "zod";

// Candidate schema for evaluation requests
const CrownEvaluationCandidateSchema = z.object({
  runId: z.string(),
  agentName: z.string(),
  gitDiff: z.string(),
});

// Request Schemas
export const CrownEvaluationRequestSchema = z.object({
  taskId: z.string(),
  taskText: z.string(),
  candidates: z.array(CrownEvaluationCandidateSchema).min(1),
  teamSlugOrId: z.string().optional(),
});

export const CrownSummarizationRequestSchema = z.object({
  taskText: z.string(),
  gitDiff: z.string(),
  teamSlugOrId: z.string().optional(),
});

export const WorkerCheckRequestSchema = z.object({
  taskId: z.string().optional(),
  taskRunId: z.string().optional(),
});

export const WorkerTaskRunInfoRequestSchema = z.object({
  taskRunId: z.string(),
});

export const WorkerAllRunsCompleteRequestSchema = z.object({
  taskId: z.string(),
});

export const WorkerFinalizeRequestSchema = z.object({
  taskId: z.string(),
  winnerRunId: z.string(),
  reason: z.string(),
  evaluationPrompt: z.string(),
  evaluationResponse: z.string(),
  candidateRunIds: z.array(z.string()).min(1),
  summary: z.string().optional(),
  pullRequest: z
    .object({
      url: z.url(),
      isDraft: z.boolean().optional(),
      state: z
        .union([
          z.literal("none"),
          z.literal("draft"),
          z.literal("open"),
          z.literal("merged"),
          z.literal("closed"),
          z.literal("unknown"),
        ])
        .optional(),
      number: z.number().int().optional(),
    })
    .optional(),
  pullRequestTitle: z.string().optional(),
  pullRequestDescription: z.string().optional(),
  summarizationPrompt: z.string().optional(),
  summarizationResponse: z.string().optional(),
});

export const WorkerCompleteRequestSchema = z.object({
  taskRunId: z.string(),
  exitCode: z.number().optional(),
});


// Type exports
export type CrownEvaluationRequest = z.infer<typeof CrownEvaluationRequestSchema>;
export type CrownSummarizationRequest = z.infer<typeof CrownSummarizationRequestSchema>;
export type WorkerCheckRequest = z.infer<typeof WorkerCheckRequestSchema>;
export type WorkerTaskRunInfoRequest = z.infer<
  typeof WorkerTaskRunInfoRequestSchema
>;
export type WorkerAllRunsCompleteRequest = z.infer<
  typeof WorkerAllRunsCompleteRequestSchema
>;
export type WorkerFinalizeRequest = z.infer<typeof WorkerFinalizeRequestSchema>;
export type WorkerCompleteRequest = z.infer<typeof WorkerCompleteRequestSchema>;
