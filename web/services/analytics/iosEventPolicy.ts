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

const COMMON_ALLOWED_PROPERTIES: ReadonlySet<string> = new Set([
  "$anon_distinct_id",
  "client_id",
  "app_version",
  "build_number",
  "os_version",
  "device_model",
  "is_authenticated",
]);

const EVENT_ALLOWED_PROPERTIES: ReadonlyMap<string, ReadonlySet<string>> = new Map(
  Object.entries({
    ios_app_launched: ["launch_type", "launched_from"],
    ios_app_foregrounded: ["launch_type", "seconds_since_backgrounded"],
    ios_session_started: ["session_id", "launch_type"],
    ios_session_ended: ["session_id", "session_duration_seconds"],
    ios_sign_in_started: ["method"],
    ios_sign_in_completed: ["is_new_user"],
    ios_sign_in_failed: ["method", "failure_reason"],
    ios_sign_in_cancelled: ["method"],
    ios_pairing_screen_viewed: ["entry"],
    ios_pairing_started: ["method", "is_first_pair", "attempt_id"],
    ios_pairing_succeeded: ["method", "is_first_pair", "attempt_id", "duration_ms", "route"],
    ios_pairing_failed: ["method", "reason", "failure_phase", "is_first_pair", "attempt_id", "duration_ms"],
    ios_connection_lost: ["was_active"],
    ios_connection_recovered: ["outage_duration_ms"],
    ios_connection_recovery_failed: ["outage_duration_ms"],
    ios_workspace_opened: ["terminal_count", "is_pinned", "source"],
    ios_terminal_input_submitted: ["byte_count", "line_count", "had_attachment"],
    ios_terminal_input_dropped: ["pending_byte_count", "reason"],
    ios_push_optin_prompt_shown: ["trigger", "prior_authorization_status"],
    ios_push_optin_granted: ["trigger"],
    ios_push_optin_declined: ["trigger", "was_os_level_predenied"],
    ios_push_token_registration_failed: ["stage", "error_code", "error_domain"],
    ios_push_tapped: ["has_workspace_id", "has_surface_id", "app_state"],
    ios_push_deeplink_resolved: ["resolved_workspace", "resolved_surface"],
    ios_push_deeplink_failed: ["reason"],
  }).map(([event, keys]) => [event, new Set(keys)]),
);

/** Whether the proxy will forward this property for a validated event. */
export function isAllowedAnalyticsProperty(event: string, property: string): boolean {
  return COMMON_ALLOWED_PROPERTIES.has(property) || EVENT_ALLOWED_PROPERTIES.get(event)?.has(property) === true;
}
