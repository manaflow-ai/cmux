"use node";

import { createAnthropic } from "@ai-sdk/anthropic";
import { createOpenAI } from "@ai-sdk/openai";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { generateObject, type LanguageModel } from "ai";
import { ConvexError, v } from "convex/values";
import { z } from "zod";
import { CLOUDFLARE_OPENAI_BASE_URL } from "@cmux/shared";
import { env } from "../../_shared/convex-env";
import { action } from "../_generated/server";

// Review output schema
const ReviewOutputSchema = z.object({
  reviewOutput: z.string().describe("Detailed markdown review of the code changes"),
  score: z.number().min(0).max(100).describe("Overall quality score from 0-100"),
  strengths: z.array(z.string()).describe("List of positive aspects of the implementation"),
  weaknesses: z.array(z.string()).describe("List of issues or concerns found"),
  suggestions: z.array(z.string()).describe("List of improvement suggestions"),
});

export type ReviewOutput = z.infer<typeof ReviewOutputSchema>;

// Model configuration per reviewer agent
const REVIEWER_MODELS = {
  claude: "claude-3-5-sonnet-20241022",
  codex: "gpt-5-mini", // OpenAI model for Codex-style review
  gemini: "gemini-2.0-flash",
} as const;

type ReviewerAgent = keyof typeof REVIEWER_MODELS;

function getReviewerModel(agent: ReviewerAgent): LanguageModel {
  switch (agent) {
    case "claude": {
      const apiKey = env.ANTHROPIC_API_KEY;
      if (!apiKey) {
        throw new ConvexError("ANTHROPIC_API_KEY not configured");
      }
      const anthropic = createAnthropic({ apiKey });
      return anthropic(REVIEWER_MODELS.claude);
    }
    case "codex": {
      const apiKey = env.OPENAI_API_KEY;
      if (!apiKey) {
        throw new ConvexError("OPENAI_API_KEY not configured");
      }
      const openai = createOpenAI({
        apiKey,
        baseURL: CLOUDFLARE_OPENAI_BASE_URL,
      });
      return openai(REVIEWER_MODELS.codex);
    }
    case "gemini": {
      const apiKey = env.GEMINI_API_KEY;
      if (!apiKey) {
        throw new ConvexError("GEMINI_API_KEY not configured");
      }
      const google = createGoogleGenerativeAI({ apiKey });
      return google(REVIEWER_MODELS.gemini) as LanguageModel;
    }
  }
}

const REVIEW_SYSTEM_PROMPT = `You are an expert code reviewer analyzing implementations from AI coding agents.
Your job is to provide thorough, constructive feedback on code changes.

Focus on:
1. Code correctness and logic errors
2. Security vulnerabilities
3. Performance issues
4. Code style and maintainability
5. Missing error handling
6. Test coverage considerations
7. Documentation quality

Be specific with line numbers and code snippets when pointing out issues.
Be constructive - suggest fixes, not just problems.`;

function buildReviewPrompt(
  taskPrompt: string,
  agentName: string,
  gitDiff: string
): string {
  return `## Task
The user requested: "${taskPrompt}"

## Implementation by ${agentName}
The following git diff shows the changes made by this agent:

\`\`\`diff
${gitDiff || "<no changes>"}
\`\`\`

## Your Review Task
Analyze this implementation and provide:
1. A detailed markdown review explaining what was done, what's good, and what needs improvement
2. A quality score from 0-100
3. Specific strengths of this implementation
4. Specific weaknesses or issues found
5. Concrete suggestions for improvement

If the diff is empty or minimal, note that the agent may not have made meaningful changes.`;
}

/**
 * Perform a code review using the specified reviewer agent
 */
export async function performReview(
  agent: ReviewerAgent,
  taskPrompt: string,
  agentName: string,
  gitDiff: string
): Promise<ReviewOutput> {
  const model = getReviewerModel(agent);

  const prompt = buildReviewPrompt(taskPrompt, agentName, gitDiff);

  try {
    const { object } = await generateObject({
      model,
      schema: ReviewOutputSchema,
      system: REVIEW_SYSTEM_PROMPT,
      prompt,
      maxRetries: 2,
    });

    return ReviewOutputSchema.parse(object);
  } catch (error) {
    console.error(`[parallelReviews] ${agent} review error:`, error);
    throw new ConvexError(`${agent} review failed`);
  }
}

/**
 * Aggregate multiple reviews into a summary for the crown evaluator
 */
export async function aggregateReviews(
  reviews: Array<{
    reviewerAgent: string;
    taskRunId: string;
    agentName: string;
    score: number;
    strengths: string[];
    weaknesses: string[];
    suggestions: string[];
    reviewOutput: string;
  }>
): Promise<string> {
  if (reviews.length === 0) {
    return "No reviews available.";
  }

  // Group reviews by taskRunId
  const byRun = new Map<string, typeof reviews>();
  for (const review of reviews) {
    const runId = review.taskRunId;
    if (!byRun.has(runId)) {
      byRun.set(runId, []);
    }
    byRun.get(runId)!.push(review);
  }

  const sections: string[] = [];

  for (const [runId, runReviews] of byRun) {
    const agentName = runReviews[0]?.agentName || runId;
    const avgScore =
      runReviews.reduce((sum, r) => sum + (r.score ?? 0), 0) / runReviews.length;

    sections.push(`## ${agentName} (Run: ${runId})`);
    sections.push(`**Average Score:** ${avgScore.toFixed(1)}/100\n`);

    for (const review of runReviews) {
      sections.push(`### ${review.reviewerAgent.toUpperCase()} Review`);
      sections.push(`Score: ${review.score}/100\n`);

      if (review.strengths.length > 0) {
        sections.push("**Strengths:**");
        review.strengths.forEach((s) => sections.push(`- ${s}`));
        sections.push("");
      }

      if (review.weaknesses.length > 0) {
        sections.push("**Weaknesses:**");
        review.weaknesses.forEach((w) => sections.push(`- ${w}`));
        sections.push("");
      }

      if (review.suggestions.length > 0) {
        sections.push("**Suggestions:**");
        review.suggestions.forEach((s) => sections.push(`- ${s}`));
        sections.push("");
      }
    }
  }

  return sections.join("\n");
}

// Convex actions

export const review = action({
  args: {
    reviewerAgent: v.union(
      v.literal("claude"),
      v.literal("codex"),
      v.literal("gemini")
    ),
    taskPrompt: v.string(),
    agentName: v.string(),
    gitDiff: v.string(),
  },
  handler: async (_ctx, args) => {
    return performReview(
      args.reviewerAgent,
      args.taskPrompt,
      args.agentName,
      args.gitDiff
    );
  },
});

export const aggregate = action({
  args: {
    reviews: v.array(
      v.object({
        reviewerAgent: v.string(),
        taskRunId: v.string(),
        agentName: v.string(),
        score: v.number(),
        strengths: v.array(v.string()),
        weaknesses: v.array(v.string()),
        suggestions: v.array(v.string()),
        reviewOutput: v.string(),
      })
    ),
  },
  handler: async (_ctx, args) => {
    return aggregateReviews(args.reviews);
  },
});
