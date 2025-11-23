import { z } from "zod";
import { typedZid } from "../utils/typed-zid";

export const WorkerRunStatusSchema = z.enum([
  "pending",
  "running",
  "completed",
  "failed",
]);
export type WorkerRunStatus = z.infer<typeof WorkerRunStatusSchema>;

export const WorkerRunContextSchema = z.object({
  token: z.string(),
  prompt: z.string(),
  agentModel: z.string().optional(),
  teamId: z.string().optional(),
  taskId: z.string().optional(),
  convexUrl: z.string().optional(),
});
export type WorkerRunContext = z.infer<typeof WorkerRunContextSchema>;

export const CrownEvaluationStatusSchema = z.enum([
  "pending",
  "in_progress",
  "succeeded",
  "error",
]);
export type CrownEvaluationStatus = z.infer<
  typeof CrownEvaluationStatusSchema
>;

export const CrownWorkerCheckResponseSchema = z.object({
  ok: z.literal(true),
  taskId: z.string(),
  allRunsFinished: z.boolean(),
  allWorkersReported: z.boolean(),
  shouldEvaluate: z.boolean(),
  singleRunWinnerId: z.string().nullable(),
  existingEvaluation: z
    .object({
      winnerRunId: z.string(),
      evaluatedAt: z.number(),
    })
    .nullable(),
  task: z.object({
    text: z.string(),
    crownEvaluationStatus: CrownEvaluationStatusSchema.nullable(),
    crownEvaluationError: z.string().nullable(),
    isCompleted: z.boolean(),
    baseBranch: z.string().nullable(),
    projectFullName: z.string().nullable(),
    autoPrEnabled: z.boolean(),
  }),
  runs: z.array(
    z.object({
      id: z.string(),
      status: WorkerRunStatusSchema,
      agentName: z.string().nullable(),
      newBranch: z.string().nullable(),
      exitCode: z.number().nullable(),
      completedAt: z.number().nullable(),
    }),
  ),
});
export type CrownWorkerCheckResponse = z.infer<
  typeof CrownWorkerCheckResponseSchema
>;

export const WorkerTaskRunDescriptorSchema = z.object({
  id: z.string(),
  taskId: z.string(),
  teamId: z.string(),
  newBranch: z.string().nullable(),
  agentName: z.string().nullable(),
  isPreviewJob: z.boolean().optional(),
});
export type WorkerTaskRunDescriptor = z.infer<
  typeof WorkerTaskRunDescriptorSchema
>;

export const WorkerTaskRunResponseSchema = z.object({
  ok: z.boolean(),
  taskRun: WorkerTaskRunDescriptorSchema.nullable(),
  task: z
    .object({
      id: z.string(),
      text: z.string(),
      projectFullName: z.string().nullable().optional(),
    })
    .nullable(),
});
export type WorkerTaskRunResponse = z.infer<typeof WorkerTaskRunResponseSchema>;

export const WorkerAllRunsCompleteResponseSchema = z.object({
  ok: z.boolean(),
  taskId: z.string(),
  allComplete: z.boolean(),
  statuses: z.array(
    z.object({
      id: z.string(),
      status: z.string(),
    }),
  ),
});
export type WorkerAllRunsCompleteResponse = z.infer<
  typeof WorkerAllRunsCompleteResponseSchema
>;

export const CandidateDataSchema = z.object({
  runId: z.string(),
  agentName: z.string(),
  gitDiff: z.string(),
  newBranch: z.string().nullable(),
});
export type CandidateData = z.infer<typeof CandidateDataSchema>;

export const CrownEvaluationResponseSchema = z.object({
  winner: z.number().int().min(0),
  reason: z.string(),
});
export type CrownEvaluationResponse = z.infer<
  typeof CrownEvaluationResponseSchema
>;

export const CrownSummarizationResponseSchema = z.object({
  summary: z.string(),
});
export type CrownSummarizationResponse = z.infer<
  typeof CrownSummarizationResponseSchema
>;

export const PullRequestMetadataSchema = z.object({
  pullRequest: z
    .object({
      url: z.url(),
      isDraft: z.boolean().optional(),
      state: z
        .enum(["none", "draft", "open", "merged", "closed", "unknown"])
        .optional(),
      number: z.number().int().optional(),
    })
    .optional(),
  title: z.string().optional(),
  description: z.string().optional(),
});
export type PullRequestMetadata = z.infer<typeof PullRequestMetadataSchema>;

export const CrownEvaluationCandidateSchema = z.object({
  runId: z.string().optional(),
  agentName: z.string().optional(),
  modelName: z.string().optional(),
  gitDiff: z.string(),
  newBranch: z.string().nullable().optional(),
  index: z.number().optional(),
});
export type CrownEvaluationCandidate = z.infer<
  typeof CrownEvaluationCandidateSchema
>;

export const CrownEvaluationRequestSchema = z.object({
  prompt: z.string(),
  candidates: z.array(CrownEvaluationCandidateSchema).min(1),
  teamSlugOrId: z.string(),
});
export type CrownEvaluationRequest = z.infer<
  typeof CrownEvaluationRequestSchema
>;

export const CrownEvaluationPromptSchema = z.object({
  prompt: z.string(),
  teamSlugOrId: z.string(),
});

export const CrownSummarizationRequestSchema = z.object({
  prompt: z.string(),
  gitDiff: z.string(),
  teamSlugOrId: z.string().optional(),
});
export type CrownSummarizationRequest = z.infer<
  typeof CrownSummarizationRequestSchema
>;

export const CrownSummarizationPromptSchema = z.object({
  prompt: z.string(),
  teamSlugOrId: z.string(),
});

export const WorkerCheckSchema = z.object({
  taskId: typedZid("tasks").optional(),
  taskRunId: typedZid("taskRuns").optional(),
  checkType: z.enum(["info", "all-complete", "crown"]).optional(),
});

export const WorkerFinalizeSchema = z.object({
  taskId: typedZid("tasks"),
  winnerRunId: typedZid("taskRuns"),
  reason: z.string(),
  evaluationPrompt: z.string(),
  evaluationResponse: z.string(),
  candidateRunIds: z.array(typedZid("taskRuns")).min(1),
  summary: z.string().optional(),
  pullRequest: z
    .object({
      url: z.string().url(),
      isDraft: z.boolean().optional(),
      state: z
        .enum(["none", "draft", "open", "merged", "closed", "unknown"])
        .optional(),
      number: z.number().int().optional(),
    })
    .optional(),
  pullRequestTitle: z.string().optional(),
  pullRequestDescription: z.string().optional(),
});

export const WorkerCompleteRequestSchema = z.object({
  taskRunId: typedZid("taskRuns"),
  exitCode: z.number().optional(),
});

export const WorkerScheduleRequestSchema = z.object({
  taskRunId: z.string(),
  scheduledStopAt: z.number().optional(),
});
