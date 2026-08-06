export const STACK_IDENTITY_STORAGE_KEY = "cmux.posthog.stack-user-id";

export type StackAnalyticsIdentity = {
  readonly id: string;
};

type PostHogIdentityClient = {
  identify(distinctId: string, properties?: Record<string, unknown>): void;
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
  const previousUserId = storage.getItem(STACK_IDENTITY_STORAGE_KEY);
  if (identity) {
    posthog.identify(identity.id, {
      stack_user_id: identity.id,
      authentication_provider: "stack",
    });
    storage.setItem(STACK_IDENTITY_STORAGE_KEY, identity.id);
    return;
  }

  // Do not reset ordinary anonymous visitors on every page load. Reset only
  // when this browser was previously attached to a signed-in Stack account.
  if (previousUserId) {
    posthog.reset();
    storage.removeItem(STACK_IDENTITY_STORAGE_KEY);
  }
}
