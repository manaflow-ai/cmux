// Server-side policy for the iOS analytics proxy. Keeps event-name validation
// and forwarding config in one place so the route handler stays thin.

/** The PostHog project key. Public (already shipped in the web client bundle),
 * overridable via env so dev/preview can point at a separate project. */
export const POSTHOG_PROJECT_KEY =
  process.env.POSTHOG_PROJECT_KEY ?? "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP";

/** The PostHog capture host (no trailing slash). */
export const POSTHOG_HOST = (process.env.POSTHOG_HOST ?? "https://r.cmux.com").replace(/\/$/, "");

/**
 * Test runners must never use the production PostHog transport by default.
 * The explicit marker is set by the web test preload; NODE_ENV and VITEST
 * also cover direct module tests that do not load that preload.
 */
export function isAnalyticsTestRun(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return (
    env.CMUX_ANALYTICS_TEST_MODE === "1" ||
    env.NODE_ENV === "test" ||
    env.VITEST === "true" ||
    env.VITEST === "1"
  );
}

/** Max request size for an analytics batch. */
export const MAX_ANALYTICS_REQUEST_BYTES = 64 * 1024;

/** Max events accepted in one batch (oversized batches are rejected, not split). */
export const MAX_ANALYTICS_BATCH_EVENTS = 100;

/** Max property keys allowed on a single event. */
export const MAX_ANALYTICS_EVENT_PROPERTIES = 64;

// Every event the iOS app may emit. Server-side allowlist so a compromised or
// buggy client cannot pollute the project with arbitrary event names. Keep in
// sync with the P0/P1/P2 catalog as new events ship.
const ALLOWED_EVENTS: ReadonlySet<string> = new Set([
  "$identify",
  // In-app purchase funnel (CmuxMobileBilling)
  "ios_paywall_viewed",
  "ios_purchase_started",
  "ios_purchase_cancelled",
  "ios_purchase_failed",
  "ios_purchase_pending",
  "ios_restore_started",
  "ios_restore_completed",
  // StoreKit catalog and purchase delivery (CmuxMobileBilling)
  "ios_products_loaded",
  "ios_products_failed",
  "ios_purchase_succeeded",
  "ios_refund_request_opened",
  "ios_refund_request_result",
  // App lifecycle + session
  "ios_app_first_launch",
  "ios_app_launched",
  "ios_app_foregrounded",
  "ios_app_backgrounded",
  "ios_session_started",
  "ios_session_ended",
  // Sign-in
  "ios_sign_in_started",
  "ios_sign_in_completed",
  "ios_sign_in_failed",
  "ios_sign_in_cancelled",
  "ios_billing_recovery_attempted",
  "ios_billing_recovery_failed",
  // Pairing
  "ios_pairing_screen_viewed",
  "ios_pairing_started",
  "ios_pairing_succeeded",
  "ios_pairing_failed",
  // Connection
  "ios_connection_lost",
  "ios_connection_recovered",
  "ios_connection_recovery_failed",
  "ios_initial_connection",
  // Workspace + terminal
  "ios_workspace_opened",
  "ios_first_frame_latency",
  "ios_terminal_input_submitted",
  "ios_terminal_input_dropped",
  // Push
  "ios_push_optin_prompt_shown",
  "ios_push_optin_granted",
  "ios_push_optin_declined",
  "ios_push_token_registration_failed",
  "ios_push_tapped",
  "ios_push_deeplink_resolved",
  "ios_push_deeplink_failed",
  "ios_crash",
]);

// Event families the app grows without a server change: every event under
// one of these prefixes is accepted. The suffix grammar keeps the name a
// plain identifier.
const ALLOWED_EVENT_FAMILIES: readonly RegExp[] = [
  /^ios_onboarding_[a-z0-9_]{1,64}$/,
  /^ios_email_verification_[a-z0-9_]{1,64}$/,
  /^ios_mac_update_hint_[a-z0-9_]{1,64}$/,
];

/** Whether the proxy will forward the given event name to PostHog. */
export function isAllowedAnalyticsEvent(name: unknown): name is string {
  return typeof name === "string" &&
    (ALLOWED_EVENTS.has(name) || ALLOWED_EVENT_FAMILIES.some((family) => family.test(name)));
}

/** Max entries kept from a list property (`product_ids`). */
export const MAX_ANALYTICS_LIST_PROPERTY_ITEMS = 32;

/**
 * Properties forwarded for an unauthenticated event. An anonymous event may
 * be a queued event from a session whose account was deleted, so it keeps
 * only build and store facts that identify no person: which app (and so
 * which channel) sent it, its version, and the StoreKit environment.
 */
export const ANONYMOUS_SAFE_PROPERTIES: ReadonlySet<string> = new Set([
  "bundle_identifier",
  "app_version",
  "build_number",
  "storekit_environment",
]);

export type IosAnalyticsChannel = "production" | "beta" | "dev" | "third_party" | "unknown";

/**
 * Release channel of the app that sent an event, from its bundle id:
 * `com.cmux.app` is the App Store app, `dev.cmux.app.beta` is TestFlight beta,
 * any other `dev.cmux.*` is a tagged dev build, and anything else is a build
 * we do not ship. `unknown` when the event carried no bundle id.
 */
export function iosAnalyticsChannel(bundleIdentifier: unknown): IosAnalyticsChannel {
  if (typeof bundleIdentifier !== "string" || bundleIdentifier.length === 0) return "unknown";
  if (bundleIdentifier === "com.cmux.app") return "production";
  if (bundleIdentifier === "dev.cmux.app.beta") return "beta";
  if (bundleIdentifier.startsWith("dev.cmux.")) return "dev";
  return "third_party";
}
