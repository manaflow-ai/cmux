export const STACK_IDENTITY_STORAGE_KEY = "cmux.posthog.stack-user-id";

export type StackAnalyticsIdentity = {
  readonly id: string;
  readonly plan: "free" | "pro" | "team";
};

type PostHogIdentityClient = {
  get_property(property: string): unknown;
  identify(distinctId: string, properties?: Record<string, unknown>): void;
  register(properties: Record<string, unknown>): void;
  reset(): void;
};

type IdentityStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

/**
 * Uses the Stack user id as PostHog's canonical distinct id. Stripe webhooks,
 * authenticated mobile analytics, and signed-in web activity can then join on
 * one server-issued identifier without sending email or profile data.
 */
export function syncStackAnalyticsIdentity(
  posthog: PostHogIdentityClient,
  storage: IdentityStorage,
  identity: StackAnalyticsIdentity | null,
): void {
  const postHogUserId = posthog.get_property("stack_user_id");
  const previousUserId = typeof postHogUserId === "string"
    ? postHogUserId
    : storage.getItem(STACK_IDENTITY_STORAGE_KEY);
  if (identity) {
    // PostHog requires a reset between authenticated people. A browser can
    // switch accounts without observing an intermediate signed-out route.
    if (previousUserId && previousUserId !== identity.id) {
      posthog.reset();
    }
    try {
      // Persist first so a failed marker write cannot leave an authenticated
      // PostHog identity that later logout handling is unable to reset.
      storage.setItem(STACK_IDENTITY_STORAGE_KEY, identity.id);
      // Keep the authoritative marker in PostHog's own persistence boundary.
      // reset() clears it together with the active distinct id.
      posthog.register({ stack_user_id: identity.id });
      posthog.identify(identity.id, {
        stack_user_id: identity.id,
        authentication_provider: "stack",
        billing_plan: identity.plan,
        is_pro: identity.plan !== "free",
      });
    } catch (error) {
      posthog.reset();
      try {
        storage.removeItem(STACK_IDENTITY_STORAGE_KEY);
      } catch {
        // The reset is the privacy boundary; storage cleanup is best-effort.
      }
      throw error;
    }
    return;
  }

  // Do not reset ordinary anonymous visitors on every page load. Reset only
  // when PostHog itself or the migration marker reports a signed-in account.
  if (previousUserId) {
    posthog.reset();
    storage.removeItem(STACK_IDENTITY_STORAGE_KEY);
  }
}
