"use node";

import { createAnthropic } from "@ai-sdk/anthropic";
import { createOpenAI } from "@ai-sdk/openai";
import { generateObject, type LanguageModel } from "ai";
import { ConvexError, v } from "convex/values";
import {
  CrownEvaluationResponseSchema,
  CrownSummarizationResponseSchema,
  type CrownEvaluationCandidate,
  type CrownEvaluationResponse,
  type CrownSummarizationResponse,
} from "../../../shared/src/convex-safe";
import { env } from "../../_shared/convex-env";
import { resolveTeamIdLoose } from "../../_shared/team";
import { action } from "../_generated/server";

const OPENAI_CROWN_MODEL = "gpt-5-mini";
const ANTHROPIC_CROWN_MODEL = "claude-3-5-sonnet-20241022";

const CrownEvaluationCandidateValidator = v.object({
  runId: v.optional(v.string()),
  agentName: v.optional(v.string()),
  modelName: v.optional(v.string()),
  gitDiff: v.string(),
  newBranch: v.optional(v.union(v.string(), v.null())),
  index: v.optional(v.number()),
});

function resolveCrownModel(modelName?: string): {
  provider: "openai" | "anthropic";
  model: LanguageModel;
} {
  const openaiKey = env.OPENAI_API_KEY;
  const anthropicKey = env.ANTHROPIC_API_KEY;

  // If a specific model is requested, try to use it
  if (modelName) {
    if (modelName.startsWith("gpt-") && openaiKey) {
      const openai = createOpenAI({ apiKey: openaiKey });
      return { provider: "openai", model: openai(modelName) };
    }
    if (modelName.startsWith("claude-") && anthropicKey) {
      const anthropic = createAnthropic({ apiKey: anthropicKey });
      return { provider: "anthropic", model: anthropic(modelName) };
    }
  }

  // Fallback to default behavior
  if (openaiKey) {
    const openai = createOpenAI({ apiKey: openaiKey });
    return { provider: "openai", model: openai(OPENAI_CROWN_MODEL) };
  }

  if (anthropicKey) {
    const anthropic = createAnthropic({ apiKey: anthropicKey });
    return {
      provider: "anthropic",
      model: anthropic(ANTHROPIC_CROWN_MODEL),
    };
  }

  throw new ConvexError(
    "Crown evaluation is not configured (missing OpenAI or Anthropic API key)",
  );
}

export async function performCrownEvaluation(
  prompt: string,
  candidates: CrownEvaluationCandidate[],
  modelName?: string,
  customSystemPrompt?: string,
): Promise<CrownEvaluationResponse> {
  const { model, provider } = resolveCrownModel(modelName);

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
      system:
        customSystemPrompt ||
        "You select the best implementation from structured diff inputs and explain briefly why.",
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
  modelName?: string,
  customSystemPrompt?: string,
): Promise<CrownSummarizationResponse> {
  const { model, provider } = resolveCrownModel(modelName);

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
        customSystemPrompt ||
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
  handler: async (ctx, args) => {
    // Get workspace settings for crown evaluation configuration
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new ConvexError("User not authenticated");
    }
    const userId = identity.subject;

    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const workspaceSettings = await ctx.db
      .query("workspaceSettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .first();

    return performCrownEvaluation(
      args.prompt,
      args.candidates,
      workspaceSettings?.crownEvaluationModel,
      workspaceSettings?.crownEvaluationSystemPrompt
    );
  },
});

    const workspaceSettings = await ctx.runQuery(
      internal.workspaceSettings.getByTeamAndUserInternal,
      {
        teamId,
        userId,
      },
    );

    return performCrownEvaluation(
      args.prompt,
      args.candidates,
      workspaceSettings?.crownEvaluationModel,
      workspaceSettings?.crownEvaluationSystemPrompt,
    );
  },
});

export const summarize = action({
  args: {
    prompt: v.string(),
    gitDiff: v.string(),
    teamSlugOrId: v.string(),
  },
  handler: async (ctx, args) => {
    // Get workspace settings for crown evaluation configuration
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new ConvexError("User not authenticated");
    }
    const userId = identity.subject;

    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const workspaceSettings = await ctx.db
      .query("workspaceSettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .first();

    return performCrownSummarization(
      args.prompt,
      args.gitDiff,
      workspaceSettings?.crownEvaluationModel,
      workspaceSettings?.crownEvaluationSystemPrompt
    );
  },
});

    const workspaceSettings = await ctx.runQuery(
      internal.workspaceSettings.getByTeamAndUserInternal,
      {
        teamId,
        userId,
      },
    );

    return performCrownSummarization(
      args.prompt,
      args.gitDiff,
      workspaceSettings?.crownEvaluationModel,
      workspaceSettings?.crownEvaluationSystemPrompt,
    );
  },
});
