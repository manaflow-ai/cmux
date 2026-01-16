import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import { authQuery } from "./users/utils";
import { getTeamId } from "../_shared/team";

// Internal query to get screenshot set by ID
export const getScreenshotSetById = internalQuery({
  args: {
    id: v.id("taskRunScreenshotSets"),
  },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.id);
  },
});

// Internal mutation to save claims to the taskRun
export const saveClaims = internalMutation({
  args: {
    runId: v.id("taskRuns"),
    claims: v.array(
      v.object({
        claim: v.string(),
        evidence: v.object({
          type: v.union(
            v.literal("image"),
            v.literal("video"),
            v.literal("codeDiff")
          ),
          screenshotIndex: v.optional(v.number()),
          imageUrl: v.optional(v.string()),
          filePath: v.optional(v.string()),
          startLine: v.optional(v.number()),
          endLine: v.optional(v.number()),
          summary: v.optional(v.string()),
          patch: v.optional(v.string()),
        }),
        timestamp: v.optional(v.number()),
      })
    ),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.runId, {
      claims: args.claims,
      claimsGeneratedAt: Date.now(),
    });
  },
});

// Query to get claims for a task run
export const getClaimsForRun = authQuery({
  args: {
    teamSlugOrId: v.string(),
    runId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);

    const run = await ctx.db.get(args.runId);
    if (!run || run.teamId !== teamId) {
      return null;
    }

    return {
      claims: run.claims ?? null,
      generatedAt: run.claimsGeneratedAt ?? null,
    };
  },
});
