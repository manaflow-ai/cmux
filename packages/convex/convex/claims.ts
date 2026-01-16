"use node";

import { createAmazonBedrock } from "@ai-sdk/amazon-bedrock";
import { generateObject } from "ai";
import { ConvexError, v } from "convex/values";
import { z } from "zod";
import { ANTHROPIC_MODEL_OPUS_45, BEDROCK_AWS_REGION } from "@cmux/shared";
import { env } from "../_shared/convex-env";
import { action, internalAction } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";

// Schema for claim evidence
const ClaimEvidenceSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("image"),
    screenshotIndex: z.number().describe("Index of the screenshot in the screenshot set (0-based)"),
    description: z.string().optional().describe("Brief description of what the screenshot shows"),
  }),
  z.object({
    type: z.literal("codeDiff"),
    filePath: z.string().describe("Path to the file that was changed"),
    startLine: z.number().optional().describe("Starting line of the relevant code"),
    endLine: z.number().optional().describe("Ending line of the relevant code"),
    summary: z.string().optional().describe("Short note for the user (keep under 12 words)"),
    patch: z.string().optional().describe("Short diff snippet copied from the provided diff"),
  }),
]);

// Schema for a single claim
const ClaimSchema = z.object({
  claim: z.string().describe("A specific claim about what was accomplished"),
  evidence: ClaimEvidenceSchema,
});

// Schema for the full LLM response
const ClaimsResponseSchema = z.object({
  claims: z.array(ClaimSchema).describe("List of claims about what was done, in chronological order"),
});

export type ClaimEvidence = z.infer<typeof ClaimEvidenceSchema>;
export type Claim = z.infer<typeof ClaimSchema>;
export type ClaimsResponse = z.infer<typeof ClaimsResponseSchema>;

/**
 * Fetch git diff from GitHub's compare API (for public repos)
 */
async function fetchGitDiffFromGitHub(
  repoFullName: string,
  baseBranch: string,
  headBranch: string
): Promise<string> {
  try {
    const url = `https://api.github.com/repos/${repoFullName}/compare/${baseBranch}...${headBranch}`;
    const response = await fetch(url, {
      headers: {
        Accept: "application/vnd.github.v3.diff",
        "User-Agent": "cmux-claims-generator",
      },
    });

    if (!response.ok) {
      console.warn("[convex.claims] GitHub compare API error", {
        status: response.status,
        statusText: response.statusText,
      });
      return "";
    }

    const diff = await response.text();
    // Truncate if too long (LLM context limit)
    const MAX_DIFF_LENGTH = 50000;
    if (diff.length > MAX_DIFF_LENGTH) {
      return diff.slice(0, MAX_DIFF_LENGTH) + "\n... (diff truncated)";
    }
    return diff;
  } catch (error) {
    console.error("[convex.claims] Failed to fetch GitHub diff", error);
    return "";
  }
}

interface ClaimsGenerationArgs {
  runId: string;
  taskPrompt: string;
  gitDiff: string;
  screenshotCount: number;
  screenshotDescriptions?: string[];
}

interface ClaimToSave {
  claim: string;
  evidence: {
    type: "image" | "video" | "codeDiff";
    screenshotIndex?: number;
    filePath?: string;
    startLine?: number;
    endLine?: number;
    summary?: string;
    patch?: string;
  };
  timestamp: number;
}

/**
 * Core claims generation logic
 */
async function generateClaimsAndSave(
  args: ClaimsGenerationArgs,
  saveClaims: (runId: Id<"taskRuns">, claims: ClaimToSave[]) => Promise<void>
): Promise<ClaimsResponse> {
  const awsBedrockToken = env.AWS_BEARER_TOKEN_BEDROCK;
  if (!awsBedrockToken) {
    throw new ConvexError("Claims generation not configured (missing AWS_BEARER_TOKEN_BEDROCK)");
  }

  const bedrock = createAmazonBedrock({
    region: BEDROCK_AWS_REGION,
    apiKey: awsBedrockToken,
  });
  const model = bedrock(ANTHROPIC_MODEL_OPUS_45);

  const screenshotInfo = args.screenshotCount > 0
    ? `\nAvailable screenshots (${args.screenshotCount} total):
${args.screenshotDescriptions?.map((desc, i) => `- Screenshot ${i}: ${desc}`).join("\n") || `Screenshots 0 to ${args.screenshotCount - 1} are available as evidence.`}`
    : "\nNo screenshots available.";

  const prompt = `You are extracting review-worthy claims from an AI coding agent's work. Keep it short and only include what a user should review.

## Task the AI was given:
${args.taskPrompt}

## Git diff of changes made:
${args.gitDiff || "<no code changes>"}
${screenshotInfo}

## Instructions:
1. Extract 1-5 important claims only. If nothing important changed, return an empty list.
2. Each claim is one short sentence (under 120 characters). No filler.
3. Focus on user-impacting behavior, UI changes, data handling, security, performance, or config changes.
4. Skip refactors, renames, formatting, logging, comments, or tests unless they change behavior.
5. Evidence rules:
   - Use "image" with screenshotIndex for visual/UI claims.
   - Use "codeDiff" with filePath, a short patch snippet copied from the diff (<= 20 lines), and a short summary.
   - If you can, include startLine/endLine for the snippet (line numbers in the new file).
6. Order claims chronologically.
7. Only claim what the evidence shows.`;

  try {
    const { object } = await generateObject({
      model,
      schema: ClaimsResponseSchema,
      system: "You extract factual claims about code changes with evidence. Be concise, specific, and accurate.",
      prompt,
      maxRetries: 2,
    });

    const result = ClaimsResponseSchema.parse(object);

    // Transform and save to database
    const claimsToSave: ClaimToSave[] = result.claims.map((claim) => ({
      claim: claim.claim,
      evidence: {
        type: claim.evidence.type as "image" | "video" | "codeDiff",
        screenshotIndex: claim.evidence.type === "image" ? claim.evidence.screenshotIndex : undefined,
        filePath: claim.evidence.type === "codeDiff" ? claim.evidence.filePath : undefined,
        startLine: claim.evidence.type === "codeDiff" ? claim.evidence.startLine : undefined,
        endLine: claim.evidence.type === "codeDiff" ? claim.evidence.endLine : undefined,
        summary: claim.evidence.type === "codeDiff" ? claim.evidence.summary : undefined,
        patch: claim.evidence.type === "codeDiff" ? claim.evidence.patch : undefined,
      },
      timestamp: Date.now(),
    }));

    await saveClaims(args.runId as Id<"taskRuns">, claimsToSave);

    return result;
  } catch (error) {
    console.error("[convex.claims] Generation error", error);
    throw new ConvexError("Claims generation failed");
  }
}

// Public action to generate claims (called from frontend)
export const generateClaims = action({
  args: {
    runId: v.id("taskRuns"),
    taskPrompt: v.string(),
    gitDiff: v.string(),
    screenshotCount: v.number(),
    screenshotDescriptions: v.optional(v.array(v.string())),
  },
  handler: async (ctx, args): Promise<ClaimsResponse> => {
    return generateClaimsAndSave(
      {
        runId: args.runId,
        taskPrompt: args.taskPrompt,
        gitDiff: args.gitDiff,
        screenshotCount: args.screenshotCount,
        screenshotDescriptions: args.screenshotDescriptions,
      },
      async (runId, claims) => {
        await ctx.runMutation(internal.claimsQueries.saveClaims, { runId, claims });
      }
    );
  },
});

// Internal action triggered automatically after screenshot collection
export const generateClaimsForRun = internalAction({
  args: {
    runId: v.id("taskRuns"),
    screenshotSetId: v.id("taskRunScreenshotSets"),
  },
  handler: async (ctx, args): Promise<void> => {
    console.log("[convex.claims] Auto-generating claims for run", { runId: args.runId });

    // Fetch task run
    const run = await ctx.runQuery(internal.taskRuns.getById, { id: args.runId });
    if (!run) {
      console.error("[convex.claims] Task run not found", { runId: args.runId });
      return;
    }

    // Fetch task
    const task = await ctx.runQuery(internal.tasks.getByIdInternal, { id: run.taskId });
    if (!task) {
      console.error("[convex.claims] Task not found", { taskId: run.taskId });
      return;
    }

    // Fetch screenshot set
    const screenshotSet = await ctx.runQuery(internal.claimsQueries.getScreenshotSetById, {
      id: args.screenshotSetId,
    });

    const screenshotCount = screenshotSet?.images?.length ?? 0;
    const screenshotDescriptions = screenshotSet?.images?.map(
      (img: { description?: string }, i: number) => img.description || `Screenshot ${i + 1}`
    ) ?? [];

    // Get task prompt from task description
    const taskPrompt = task.description || run.prompt || "No task description available";

    // Try to fetch git diff
    let gitDiff = "";
    const repoFullName = task.projectFullName?.trim();
    const headBranch = run.newBranch?.trim();
    const baseBranch = task.baseBranch?.trim() || "main";

    if (repoFullName && headBranch) {
      console.log("[convex.claims] Fetching git diff", { repoFullName, baseBranch, headBranch });
      gitDiff = await fetchGitDiffFromGitHub(repoFullName, baseBranch, headBranch);
    }

    // Generate claims
    try {
      await generateClaimsAndSave(
        {
          runId: args.runId,
          taskPrompt,
          gitDiff,
          screenshotCount,
          screenshotDescriptions,
        },
        async (runId, claims) => {
          await ctx.runMutation(internal.claimsQueries.saveClaims, { runId, claims });
        }
      );
      console.log("[convex.claims] Claims generated successfully", { runId: args.runId });
    } catch (error) {
      console.error("[convex.claims] Failed to generate claims", { runId: args.runId, error });
    }
  },
});
