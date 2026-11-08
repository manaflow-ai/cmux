// Demonstration-content flag for the App Review demo account.
//
// The iOS app activates its demonstration computer (sample workspaces,
// notifications, interactive canned terminals) when the signed-in account's
// Stack `clientReadOnlyMetadata` carries `cmuxReviewDemoContent: true` — the
// client reads it off the session payload it already fetches at sign-in
// (`CMUXAuthUser.demonstrationContentEnabled`). This module owns the
// server-side write, mirroring the `cmuxPlan`/`cmuxVmPlan` metadata pattern in
// services/billing/pro.ts: preserve every other key and set or remove only
// ours. Set the flag with `bun scripts/set-review-demo-content.ts`.

export const REVIEW_DEMO_CONTENT_METADATA_KEY = "cmuxReviewDemoContent";

// Mirrors Stack's ReadonlyJson so `user.update` stays assignable.
export type ReviewDemoContentJson =
  | null
  | boolean
  | number
  | string
  | readonly ReviewDemoContentJson[]
  | { readonly [key: string]: ReviewDemoContentJson };

export type ReviewDemoContentUser = {
  readonly clientReadOnlyMetadata?: unknown;
  update(options: {
    clientReadOnlyMetadata: ReviewDemoContentJson;
  }): Promise<unknown>;
};

/**
 * Returns the metadata object with the demonstration flag applied: set to the
 * literal `true` when enabling, removed entirely when disabling (the client
 * treats every non-`true` shape as off, so no tombstone value is needed).
 * Every other key is preserved verbatim.
 */
export function metadataApplyingReviewDemoContent(
  raw: unknown,
  enabled: boolean,
): Record<string, unknown> {
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  if (enabled) {
    metadata[REVIEW_DEMO_CONTENT_METADATA_KEY] = true;
  } else {
    delete metadata[REVIEW_DEMO_CONTENT_METADATA_KEY];
  }
  return metadata;
}

/**
 * Whether a metadata snapshot currently enables demonstration content. Only
 * the literal boolean `true` counts, matching the client's fail-closed parse.
 */
export function reviewDemoContentEnabled(raw: unknown): boolean {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return false;
  return (
    (raw as Record<string, unknown>)[REVIEW_DEMO_CONTENT_METADATA_KEY] === true
  );
}

/**
 * Sets or clears the demonstration-content flag on a Stack user, skipping the
 * write when the flag already has the requested value. Returns the metadata
 * snapshot that is now current.
 */
export async function setReviewDemoContent(
  user: ReviewDemoContentUser,
  enabled: boolean,
): Promise<Record<string, unknown>> {
  const current = metadataApplyingReviewDemoContent(
    user.clientReadOnlyMetadata,
    reviewDemoContentEnabled(user.clientReadOnlyMetadata),
  );
  if (reviewDemoContentEnabled(current) === enabled) {
    return current;
  }
  const next = metadataApplyingReviewDemoContent(
    user.clientReadOnlyMetadata,
    enabled,
  );
  await user.update({
    clientReadOnlyMetadata: next as ReviewDemoContentJson,
  });
  return next;
}
