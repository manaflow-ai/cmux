import { v } from "convex/values";
import { internalAction } from "./_generated/server";
import { env } from "../_shared/convex-env";

const MORPH_API_BASE_URL = "https://cloud.morph.so";

export const pauseMorphInstance = internalAction({
  args: {
    sandboxInstanceId: v.string(),
  },
  handler: async (_ctx, args) => {
    const apiKey = env.MORPH_API_KEY;
    if (!apiKey) {
      console.warn(
        "[codeReview] MORPH_API_KEY not configured; skipping Morph pause request",
        { sandboxInstanceId: args.sandboxInstanceId }
      );
      return;
    }

    const url = `${MORPH_API_BASE_URL}/api/instances/${encodeURIComponent(
      args.sandboxInstanceId
    )}/pause`;
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${apiKey}`,
        },
      });

      if (!response.ok) {
        const text = await response.text().catch(() => "");
        console.warn("[codeReview] Failed to pause Morph instance", {
          sandboxInstanceId: args.sandboxInstanceId,
          status: response.status,
          bodyPreview: text.slice(0, 512),
        });
      }
    } catch (error) {
      console.error("[codeReview] Error pausing Morph instance", {
        sandboxInstanceId: args.sandboxInstanceId,
        error,
      });
    }
  },
});
