"use node";

import { v } from "convex/values";
import { PREVIEW_PAYWALL_FREE_PR_LIMIT } from "../_shared/preview-paywall";
import { stackServerAppJs } from "../_shared/stackServerAppJs";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";
import type { PreviewQuotaResult } from "./preview_quota";

const DEFAULT_PREVIEW_PAYWALL_PRODUCT_ID = "preview-pro";

/**
 * Check if a user has preview quota remaining
 *
 * Flow:
 * 1. First check Stack Auth for paid product (preview-pro)
 * 2. If no paid product, check free tier limit (10 unique PRs)
 * 3. Return whether the user can run another preview
 */
export const checkPreviewQuota = internalAction({
  args: {
    userId: v.string(),
  },
  handler: async (ctx, { userId }): Promise<PreviewQuotaResult> => {
    // Use process.env directly to avoid t3-env validation at bundle time
    const paywallProductId =
      process.env.NEXT_PUBLIC_PREVIEW_PAYWALL_PRODUCT_ID ||
      DEFAULT_PREVIEW_PAYWALL_PRODUCT_ID;

    // Step 1: Check Stack Payments for a paid product
    try {
      const serverUser = await stackServerAppJs.getUser(userId);
      if (serverUser) {
        const products = await serverUser.listProducts({ limit: 100 });
        const hasPaidProduct = products.some(
          (product) => product.id === paywallProductId && product.quantity > 0,
        );

        if (hasPaidProduct) {
          return {
            allowed: true,
            remainingRuns: Number.MAX_SAFE_INTEGER,
            isPaid: true,
          };
        }
      }
    } catch (error) {
      console.warn(
        "[preview_quota] Error checking Stack products, falling back to free tier",
        {
          userId,
          error: error instanceof Error ? error.message : String(error),
        },
      );
    }

    // Step 2: Check free tier limit
    const usedRuns = await ctx.runQuery(
      internal.previewRuns.getUniquePullRequestCountByUser,
      { userId, cap: PREVIEW_PAYWALL_FREE_PR_LIMIT },
    );

    console.log("[preview_quota] Checking free tier limit", {
      userId,
      usedRuns,
      limit: PREVIEW_PAYWALL_FREE_PR_LIMIT,
      exceedsLimit: usedRuns >= PREVIEW_PAYWALL_FREE_PR_LIMIT,
    });

    if (usedRuns >= PREVIEW_PAYWALL_FREE_PR_LIMIT) {
      console.log("[preview_quota] User exceeded free tier limit", {
        userId,
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

    console.log("[preview_quota] User has remaining quota", {
      userId,
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
