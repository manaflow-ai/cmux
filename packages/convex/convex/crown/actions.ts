"use node";

import { createAnthropic } from "@ai-sdk/anthropic";
import { createOpenAI } from "@ai-sdk/openai";
import { generateObject, type LanguageModel } from "ai";
import { ConvexError, v } from "convex/values";
import {
  CROWN_MODEL_OPTIONS,
  CrownEvaluationResponseSchema,
  CrownSummarizationResponseSchema,
  DEFAULT_CROWN_SYSTEM_PROMPT,
  type CrownEvaluationCandidate,
  type CrownEvaluationResponse,
  type CrownSummarizationResponse,
} from "@cmux/shared/convex-safe";
import { CLOUDFLARE_OPENAI_BASE_URL } from "@cmux/shared";
import { env } from "../../_shared/convex-env";
import { internal } from "../_generated/api";
import { action } from "../_generated/server";

// Default model when Anthropic key is available
const DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-4-5-20250514";
// Fallback when only OpenAI key is available
const DEFAULT_OPENAI_MODEL = "gpt-5-mini";

const CrownEvaluationCandidateValidator = v.object({
  runId: v.optional(v.string()),
  agentName: v.optional(v.string()),
  modelName: v.optional(v.string()),
  gitDiff: v.string(),
  newBranch: v.optional(v.union(v.string(), v.null())),
  index: v.optional(v.number()),
});

function resolveCrownModel(configuredModel?: string): {
  provider: "openai" | "anthropic";
  model: LanguageModel;
} {
  const anthropicKey = env.ANTHROPIC_API_KEY;
  const openaiKey = env.OPENAI_API_KEY;

  // If a specific model is configured, use it
  if (configuredModel) {
    const modelConfig = CROWN_MODEL_OPTIONS.find(
      (opt) => opt.value === configuredModel
    );

    if (modelConfig) {
      if (modelConfig.provider === "anthropic" && anthropicKey) {
        const anthropic = createAnthropic({ apiKey: anthropicKey });
        return { provider: "anthropic", model: anthropic(modelConfig.value) };
      }
      if (modelConfig.provider === "openai" && openaiKey) {
        const openai = createOpenAI({
          apiKey: openaiKey,
          baseURL: CLOUDFLARE_OPENAI_BASE_URL,
        });
        return { provider: "openai", model: openai(modelConfig.value) };
      }
      // Configured model's provider key not available, fall through to defaults
      console.warn(
        `[convex.crown] Configured model ${configuredModel} requires ${modelConfig.provider} key which is not available, falling back to default`
      );
    }
  }

  // Default: prefer Anthropic (claude-sonnet-4-5), fallback to OpenAI
  if (anthropicKey) {
    const anthropic = createAnthropic({ apiKey: anthropicKey });
    return { provider: "anthropic", model: anthropic(DEFAULT_ANTHROPIC_MODEL) };
  }

  if (openaiKey) {
    const openai = createOpenAI({
      apiKey: openaiKey,
      baseURL: CLOUDFLARE_OPENAI_BASE_URL,
    });
    return { provider: "openai", model: openai(DEFAULT_OPENAI_MODEL) };
  }

  throw new ConvexError(
    "Crown evaluation is not configured (missing OpenAI or Anthropic API key)"
  );
}

export async function performCrownEvaluation(
  prompt: string,
  candidates: CrownEvaluationCandidate[],
  options?: { configuredModel?: string; customSystemPrompt?: string }
): Promise<CrownEvaluationResponse> {
  const { model, provider } = resolveCrownModel(options?.configuredModel);
  const systemPrompt = options?.customSystemPrompt || DEFAULT_CROWN_SYSTEM_PROMPT;

  const normalizedCandidates = candidates.map((candidate, idx) => {
    const resolvedIndex = candidate.index ?? idx;
    return {
      index: resolvedIndex,
      runId: candidate.runId,
      agentName: candidate.agentName,
      modelName:
        candidate.modelName ??
        candidate.agentName ??
        (candidate.runId ? `run-${candidate.runId}` : undefined) ??
        `candidate-${resolvedIndex}`,
      gitDiff: candidate.gitDiff,
      newBranch: candidate.newBranch ?? null,
    };
  });

  const evaluationData = {
    prompt,
    candidates: normalizedCandidates,
  };

  const evaluationPrompt = `You are evaluating code implementations from different AI models.

Here are the candidates to evaluate:
${JSON.stringify(evaluationData, null, 2)}

NOTE: The git diffs shown contain only actual code changes. Lock files, build artifacts, and other non-essential files have been filtered out.

Analyze these implementations and select the best one based on:
1. Code quality and correctness
2. Completeness of the solution
3. Following best practices
4. Actually having meaningful code changes (if one has no changes, prefer the one with changes)

Respond with a JSON object containing:
- "winner": the index (0-based) of the best implementation
- "reason": a brief explanation of why this implementation was chosen

Example response:
{"winner": 0, "reason": "Model claude/sonnet-4 provided a more complete implementation with better error handling and cleaner code structure."}

IMPORTANT: Respond ONLY with the JSON object, no other text.`;

  try {
    const { object } = await generateObject({
      model,
      schema: CrownEvaluationResponseSchema,
      system: systemPrompt,
      prompt: evaluationPrompt,
      ...(provider === "openai" ? {} : { temperature: 0 }),
      maxRetries: 2,
    });

    return CrownEvaluationResponseSchema.parse(object);
  } catch (error) {
    console.error("[convex.crown] Evaluation error", error);
    throw new ConvexError("Evaluation failed");
  }
}

export async function performCrownSummarization(
  prompt: string,
  gitDiff: string,
  options?: { configuredModel?: string }
): Promise<CrownSummarizationResponse> {
  const { model, provider } = resolveCrownModel(options?.configuredModel);

  const summarizationPrompt = `You are an expert reviewer summarizing a pull request.

GOAL
- Explain succinctly what changed and why.
- Call out areas the user should review carefully.
- Provide a quick test plan to validate the changes.

CONTEXT
- User's original request:
${prompt}
- Relevant diffs (unified):
${gitDiff || "<no code changes captured>"}

INSTRUCTIONS
- Base your summary strictly on the provided diffs and request.
- Be specific about files and functions when possible.
- Prefer clear bullet points over prose. Keep it under ~300 words.
- If there are no code changes, say so explicitly and suggest next steps.

OUTPUT FORMAT (Markdown)
## PR Review Summary
- What Changed: bullet list
- Review Focus: bullet list (risks/edge cases)
- Test Plan: bullet list of practical steps
- Follow-ups: optional bullets if applicable
`;

  try {
    const { object } = await generateObject({
      model,
      schema: CrownSummarizationResponseSchema,
      system:
        "You are an expert reviewer summarizing pull requests. Provide a clear, concise summary following the requested format.",
      prompt: summarizationPrompt,
      ...(provider === "openai" ? {} : { temperature: 0 }),
      maxRetries: 2,
    });

    return CrownSummarizationResponseSchema.parse(object);
  } catch (error) {
    console.error("[convex.crown] Summarization error", error);
    throw new ConvexError("Summarization failed");
  }
}

export const evaluate = action({
  args: {
    prompt: v.string(),
    candidates: v.array(CrownEvaluationCandidateValidator),
    teamSlugOrId: v.string(),
  },
  handler: async (ctx, args): Promise<CrownEvaluationResponse> => {
    // Fetch workspace settings for crown model and system prompt
    // Use internal query to avoid circular reference
    const identity = await ctx.auth.getUserIdentity();
    let workspaceSettings: {
      crownModel?: string;
      crownSystemPrompt?: string;
    } | null = null;

    if (identity) {
      workspaceSettings = await ctx.runQuery(
        internal.workspaceSettings.getByTeamAndUserInternal,
        { teamId: args.teamSlugOrId, userId: identity.subject }
      );
    }

    return performCrownEvaluation(args.prompt, args.candidates, {
      configuredModel: workspaceSettings?.crownModel,
      customSystemPrompt: workspaceSettings?.crownSystemPrompt,
    });
  },
});

export const summarize = action({
  args: {
    prompt: v.string(),
    gitDiff: v.string(),
    teamSlugOrId: v.string(),
  },
  handler: async (ctx, args): Promise<CrownSummarizationResponse> => {
    // Fetch workspace settings for crown model
    // Use internal query to avoid circular reference
    const identity = await ctx.auth.getUserIdentity();
    let workspaceSettings: { crownModel?: string } | null = null;

    if (identity) {
      workspaceSettings = await ctx.runQuery(
        internal.workspaceSettings.getByTeamAndUserInternal,
        { teamId: args.teamSlugOrId, userId: identity.subject }
      );
    }

    return performCrownSummarization(args.prompt, args.gitDiff, {
      configuredModel: workspaceSettings?.crownModel,
    });
  },
});
