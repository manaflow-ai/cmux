import { v } from "convex/values";
import {
  PREVIEW_PAYWALL_FREE_PR_LIMIT,
  PREVIEW_PAYWALL_STATE_REASON,
} from "../_shared/preview-paywall";
import { getTeamId } from "../_shared/team";
import { authQuery } from "./users/utils";

export type PreviewQuotaResult =
  | { allowed: true; remainingRuns: number; isPaid: boolean }
  | { allowed: false; reason: "quota_exceeded"; usedRuns: number; limit: number };

/**
 * Get quota info for display in the subscription page
 * This is a public query that can be called from the frontend.
 * Quota is now tracked per-team (not per-user).
 */
export const getQuotaInfo = authQuery({
  args: {
    teamSlugOrId: v.string(),
  },
  handler: async (
    ctx,
    { teamSlugOrId },
  ): Promise<{ usedRuns: number; remainingRuns: number; freeLimit: number }> => {
    const teamId = await getTeamId(ctx, teamSlugOrId);

    // Fetch enough runs to reliably count unique PRs up to the cap.
    // Using .take(500) avoids pagination issues in Convex.
    const runs = await ctx.db
      .query("previewRuns")
      .withIndex("by_team_created", (q) => q.eq("teamId", teamId))
      .order("desc")
      .take(500);

    const uniquePullRequests = new Set<string>();
    for (const run of runs) {
      // Skip paywall-blocked runs
      if (run.stateReason === PREVIEW_PAYWALL_STATE_REASON) {
        continue;
      }
      uniquePullRequests.add(`${run.repoFullName}#${run.prNumber}`);
      if (uniquePullRequests.size >= PREVIEW_PAYWALL_FREE_PR_LIMIT) {
        break;
      }
    }

    const usedRuns = uniquePullRequests.size;

    return {
      usedRuns,
      remainingRuns: Math.max(0, PREVIEW_PAYWALL_FREE_PR_LIMIT - usedRuns),
      freeLimit: PREVIEW_PAYWALL_FREE_PR_LIMIT,
    };
  },
});
