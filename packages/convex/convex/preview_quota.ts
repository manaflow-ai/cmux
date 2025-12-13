import { v } from "convex/values";
import { PREVIEW_PAYWALL_FREE_PR_LIMIT } from "../_shared/preview-paywall";
import { getTeamId } from "../_shared/team";
import { authQuery } from "./users/utils";

export type PreviewQuotaResult =
  | { allowed: true; remainingRuns: number; isPaid: boolean }
  | { allowed: false; reason: "quota_exceeded"; usedRuns: number; limit: number };

/**
 * Get quota info for display in the subscription page
 * This is a public query that can be called from the frontend
 */
export const getQuotaInfo = authQuery({
  args: {
    teamSlugOrId: v.string(),
  },
  handler: async (
    ctx,
    { teamSlugOrId },
  ): Promise<{ usedRuns: number; remainingRuns: number; freeLimit: number }> => {
    // Validate team selection for the current user (quota is tracked per-user).
    await getTeamId(ctx, teamSlugOrId);

    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required");
    }

    const uniquePullRequests = new Set<string>();
    let cursor: string | null = null;

    while (uniquePullRequests.size < PREVIEW_PAYWALL_FREE_PR_LIMIT) {
      const results = await ctx.db
        .query("previewRuns")
        .withIndex("by_user_created", (q) =>
          q.eq("createdByUserId", identity.subject),
        )
        .order("desc")
        .paginate({ cursor, numItems: 200 });

      for (const run of results.page) {
        uniquePullRequests.add(`${run.repoFullName}#${run.prNumber}`);
        if (uniquePullRequests.size >= PREVIEW_PAYWALL_FREE_PR_LIMIT) {
          break;
        }
      }

      cursor = results.continueCursor;
      if (!cursor) break;
    }

    const usedRuns = uniquePullRequests.size;

    return {
      usedRuns,
      remainingRuns: Math.max(0, PREVIEW_PAYWALL_FREE_PR_LIMIT - usedRuns),
      freeLimit: PREVIEW_PAYWALL_FREE_PR_LIMIT,
    };
  },
});
