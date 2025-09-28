"use node";

import { createAnthropic } from "@ai-sdk/anthropic";
import { generateObject } from "ai";
import { ConvexError, v } from "convex/values";
import type {
  CrownEvaluationLLMResponse,
  CrownEvaluationResponse,
  CrownSummarizationLLMResponse,
  CrownSummarizationResponse,
} from "@cmux/shared/crown/types";
import { env } from "../../_shared/convex-env";
import { action } from "../_generated/server";
import {
  CrownEvaluationCandidateSchema,
  buildEvaluationPrompt,
  buildSummarizationPrompt,
} from "./prompts";
import {
  CrownEvaluationLLMResponseSchema,
  CrownSummarizationLLMResponseSchema,
} from "@cmux/shared/crown/types";

const MODEL_NAME = "claude-3-5-sonnet-20241022";

export async function performCrownEvaluation(
  apiKey: string,
  prompt: string
): Promise<CrownEvaluationLLMResponse> {
  const anthropic = createAnthropic({ apiKey });

  try {
    const { object } = await generateObject({
      model: anthropic(MODEL_NAME),
      schema: CrownEvaluationLLMResponseSchema,
      system:
        "You select the best implementation from structured diff inputs and explain briefly why.",
      prompt,
      temperature: 0,
      maxRetries: 2,
    });

    const evaluationResponse = CrownEvaluationLLMResponseSchema.parse(object);
    return evaluationResponse;
  } catch (error) {
    console.error("[convex.crown] Evaluation error", error);
    throw new ConvexError("Evaluation failed");
  }
}

export async function performCrownSummarization(
  apiKey: string,
  prompt: string
): Promise<CrownSummarizationLLMResponse> {
  const anthropic = createAnthropic({ apiKey });

  try {
    const { object } = await generateObject({
      model: anthropic(MODEL_NAME),
      schema: CrownSummarizationLLMResponseSchema,
      system:
        "You are an expert reviewer summarizing pull requests. Provide a clear, concise summary following the requested format.",
      prompt,
      temperature: 0,
      maxRetries: 2,
    });

    const summarizationResponse = CrownSummarizationLLMResponseSchema.parse(object);
    return summarizationResponse;
  } catch (error) {
    console.error("[convex.crown] Summarization error", error);
    throw new ConvexError("Summarization failed");
  }
}

export const evaluate = action({
  args: {
    taskText: v.string(),
    candidates: v.array(
      v.object({
        runId: v.string(),
        agentName: v.string(),
        gitDiff: v.string(),
      })
    ),
    teamSlugOrId: v.string(),
  },
  handler: async (_ctx, args) => {
    const apiKey = env.ANTHROPIC_API_KEY;

    const validatedCandidates = args.candidates.map((candidate) =>
      CrownEvaluationCandidateSchema.parse(candidate)
    );
    const prompt = buildEvaluationPrompt(args.taskText, validatedCandidates);

    const result = await performCrownEvaluation(apiKey, prompt);

    const response = {
      ...result,
      prompt,
    } satisfies CrownEvaluationResponse;

    return response;
  },
});

export const summarize = action({
  args: {
    taskText: v.string(),
    gitDiff: v.string(),
    teamSlugOrId: v.optional(v.string()),
  },
  handler: async (_ctx, args) => {
    const apiKey = env.ANTHROPIC_API_KEY;
    const prompt = buildSummarizationPrompt(args.taskText, args.gitDiff);

    const result = await performCrownSummarization(apiKey, prompt);

    const response = {
      ...result,
      prompt,
    } satisfies CrownSummarizationResponse;

    return response;
  },
});
