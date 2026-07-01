// Server-side policy for the iOS analytics proxy. Keeps event-name validation
// and forwarding config in one place so the route handler stays thin.

/** The PostHog project key. Public (already shipped in the web client bundle),
 * overridable via env so dev/preview can point at a separate project. */
export const POSTHOG_PROJECT_KEY =
  process.env.POSTHOG_PROJECT_KEY ?? "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP";

/** The PostHog capture host (no trailing slash). */
export const POSTHOG_HOST = (process.env.POSTHOG_HOST ?? "https://r.cmux.com").replace(/\/$/, "");

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
  // Pairing
  "ios_pairing_screen_viewed",
  "ios_pairing_started",
  "ios_pairing_succeeded",
  "ios_pairing_failed",
  // Connection
  "ios_connection_lost",
  "ios_connection_recovered",
  "ios_connection_recovery_failed",
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

/** Whether the proxy will forward the given event name to PostHog. */
export function isAllowedAnalyticsEvent(name: unknown): name is string {
  return typeof name === "string" && ALLOWED_EVENTS.has(name);
}
