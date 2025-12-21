"use node";

import { v } from "convex/values";
import { PREVIEW_PAYWALL_FREE_PR_LIMIT } from "../_shared/preview-paywall";
import { stackServerAppJs } from "../_shared/stackServerAppJs";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";
import type { PreviewQuotaResult } from "./preview_quota";

// Stack Auth item ID for preview subscription
// Reference: Stack Auth docs - team.getItem() returns Item with nonNegativeQuantity
const PREVIEW_SUBSCRIPTION_ITEM_ID = "preview-team-subscription";

/**
 * Check if a team has preview quota remaining
 *
 * Flow:
 * 1. First check if team has an active preview subscription via Stack Auth
 * 2. If no subscription, check free tier limit (10 unique PRs per team)
 * 3. Return whether the team can run another preview
 */
export const checkPreviewQuota = internalAction({
  args: {
    teamId: v.string(),
  },
  handler: async (ctx, { teamId }): Promise<PreviewQuotaResult> => {
    // Step 1: Check if team has an active preview subscription via Stack Auth
    try {
      const team = await stackServerAppJs.getTeam(teamId);
      if (team) {
        const item = await team.getItem(PREVIEW_SUBSCRIPTION_ITEM_ID);
        if (item.nonNegativeQuantity > 0) {
          console.log("[preview_quota] Team has active preview subscription", {
            teamId,
            itemId: PREVIEW_SUBSCRIPTION_ITEM_ID,
            quantity: item.quantity,
          });
          return {
            allowed: true,
            remainingRuns: Number.MAX_SAFE_INTEGER,
            isPaid: true,
          };
        }
      }
    } catch (error) {
      // Log but don't fail - fall through to free tier check
      console.error("[preview_quota] Failed to check Stack Auth subscription", {
        teamId,
        error,
      });
    }

    // Step 2: Check free tier limit
    const usedRuns = await ctx.runQuery(
      internal.previewRuns.getUniquePullRequestCountByTeam,
      { teamId, cap: PREVIEW_PAYWALL_FREE_PR_LIMIT },
    );

    console.log("[preview_quota] Checking free tier limit", {
      teamId,
      usedRuns,
      limit: PREVIEW_PAYWALL_FREE_PR_LIMIT,
      exceedsLimit: usedRuns >= PREVIEW_PAYWALL_FREE_PR_LIMIT,
    });

    if (usedRuns >= PREVIEW_PAYWALL_FREE_PR_LIMIT) {
      console.log("[preview_quota] Team exceeded free tier limit", {
        teamId,
        usedRuns,
        limit: PREVIEW_PAYWALL_FREE_PR_LIMIT,
      });

      return {
        allowed: false,
        reason: "quota_exceeded",
        usedRuns,
        limit: PREVIEW_PAYWALL_FREE_PR_LIMIT,
      };
    }

    console.log("[preview_quota] Team has remaining quota", {
      teamId,
      usedRuns,
      remainingRuns: PREVIEW_PAYWALL_FREE_PR_LIMIT - usedRuns,
    });

    return {
      allowed: true,
      remainingRuns: PREVIEW_PAYWALL_FREE_PR_LIMIT - usedRuns,
      isPaid: false,
    };
  },
});

/**
 * Consume one preview run from the user's quota
 * Call this AFTER successfully starting a preview run
 *
 * For paid users with subscription: No action needed (unlimited)
 * For free users: No action needed (count is tracked by completed runs)
 */
export const consumePreviewRun = internalAction({
  args: {
    userId: v.string(),
  },
  handler: async (_ctx, { userId }): Promise<{ consumed: boolean; error?: string }> => {
    // With subscription-based model (not item-based), we don't need to decrement anything.
    // Free tier usage is tracked by counting preview runs in the database.
    // Paid users have unlimited access via their subscription.
    console.log("[preview_quota] Preview run consumed (no decrement needed)", { userId });
    return { consumed: true };
  },
});
