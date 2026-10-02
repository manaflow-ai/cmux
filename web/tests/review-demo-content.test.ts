import { describe, expect, test } from "bun:test";

import {
  REVIEW_DEMO_CONTENT_METADATA_KEY,
  metadataApplyingReviewDemoContent,
  reviewDemoContentEnabled,
  setReviewDemoContent,
  type ReviewDemoContentJson,
} from "../services/account/reviewDemoContent";

describe("review demo content metadata", () => {
  test("enabling sets the literal true and preserves other keys", () => {
    const next = metadataApplyingReviewDemoContent(
      { cmuxPlan: "pro", cmuxVmPlan: "founders" },
      true,
    );
    expect(next).toEqual({
      cmuxPlan: "pro",
      cmuxVmPlan: "founders",
      [REVIEW_DEMO_CONTENT_METADATA_KEY]: true,
    });
  });

  test("disabling removes the key entirely", () => {
    const next = metadataApplyingReviewDemoContent(
      { cmuxPlan: "pro", [REVIEW_DEMO_CONTENT_METADATA_KEY]: true },
      false,
    );
    expect(next).toEqual({ cmuxPlan: "pro" });
  });

  test("non-object metadata is replaced by a fresh object", () => {
    expect(metadataApplyingReviewDemoContent(null, true)).toEqual({
      [REVIEW_DEMO_CONTENT_METADATA_KEY]: true,
    });
    expect(metadataApplyingReviewDemoContent("bogus", false)).toEqual({});
    expect(metadataApplyingReviewDemoContent([1, 2], true)).toEqual({
      [REVIEW_DEMO_CONTENT_METADATA_KEY]: true,
    });
  });

  test("only the literal true reads as enabled", () => {
    expect(reviewDemoContentEnabled({ [REVIEW_DEMO_CONTENT_METADATA_KEY]: true })).toBe(true);
    expect(reviewDemoContentEnabled({ [REVIEW_DEMO_CONTENT_METADATA_KEY]: "true" })).toBe(false);
    expect(reviewDemoContentEnabled({ [REVIEW_DEMO_CONTENT_METADATA_KEY]: 1 })).toBe(false);
    expect(reviewDemoContentEnabled({})).toBe(false);
    expect(reviewDemoContentEnabled(null)).toBe(false);
  });

  test("setReviewDemoContent writes once and skips no-op updates", async () => {
    const updates: ReviewDemoContentJson[] = [];
    const user = {
      clientReadOnlyMetadata: { cmuxPlan: "pro" } as unknown,
      update: async (options: { clientReadOnlyMetadata: ReviewDemoContentJson }) => {
        updates.push(options.clientReadOnlyMetadata);
      },
    };

    const enabled = await setReviewDemoContent(user, true);
    expect(updates).toHaveLength(1);
    expect(reviewDemoContentEnabled(enabled)).toBe(true);
    expect((enabled as Record<string, unknown>).cmuxPlan).toBe("pro");

    // Already-off metadata: disabling writes nothing.
    const noop = await setReviewDemoContent(user, false);
    expect(updates).toHaveLength(1);
    expect(reviewDemoContentEnabled(noop)).toBe(false);
  });
});
