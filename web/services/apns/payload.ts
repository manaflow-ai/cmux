// Pure, dependency-free helpers for building APNs requests. Kept separate from
// the http2/crypto sender so they can be unit-tested in isolation.

export type ApnsEnvironment = "sandbox" | "production";

export const APNS_HOSTS: Record<ApnsEnvironment, string> = {
  sandbox: "api.sandbox.push.apple.com",
  production: "api.push.apple.com",
};

/** APNs host for a stored token's environment (defaults to production). */
export function apnsHostForEnvironment(environment: string): string {
  return environment === "sandbox" ? APNS_HOSTS.sandbox : APNS_HOSTS.production;
}

export interface ApnsNotificationInput {
  /**
   * `notify` (default) is the visible terminal-banner mirror; `dismiss` is the
   * banner-less Mac→iOS dismiss-sync push (`content-available` + badge +
   * `cmux.dismissedIds`) fanned out to every registered device.
   */
  readonly kind?: "notify" | "dismiss";
  readonly title: string;
  readonly subtitle?: string | null;
  readonly body: string;
  readonly workspaceId?: string | null;
  readonly surfaceId?: string | null;
  /** Whether a tap may resolve the surface outside `workspaceId`. */
  readonly retargetsToLiveSurfaceOwner?: boolean;
  readonly macDeviceId?: string | null;
  /**
   * Stable Mac-side notification id. Surfaced in the payload as
   * `cmux.notificationId` so an iOS swipe-dismiss can tell the Mac which
   * notification was cleared. The sender also stamps it as `apns-collapse-id`
   * so a later Mac→iOS dismiss can target this exact delivered banner.
   */
  readonly notificationId?: string | null;
  /** The dismissed notification ids carried by a `dismiss` push. */
  readonly dismissedIds?: readonly string[];
  /**
   * Authoritative unread count computed by the Mac at send time; emitted as
   * `aps.badge` so the icon badge is always SET to the absolute total (never
   * incremented locally) and drift self-heals. `null`/absent leaves the badge
   * untouched.
   */
  readonly badgeCount?: number | null;
  /** When true, replace real terminal text with a generic fallback. Keep the
   * fallback literal until device tokens carry client localization capability. */
  readonly hideContent?: boolean;
}

/**
 * APNs `aps.category` set on every cmux terminal push. iOS registers a
 * matching ``UNNotificationCategory`` with `customDismissAction` so a
 * swipe/clear delivers `UNNotificationDismissActionIdentifier` to the app,
 * which forwards the dismiss to the Mac. Keep this in sync with the iOS
 * category id.
 */
export const CMUX_APNS_CATEGORY = "cmux.terminal";

/**
 * Build the APNs JSON payload. Adds the workspace/surface ids, live-owner
 * retargeting provenance, Mac id, and notification id under `cmux` so a tap
 * can deep-link without crossing a confined workspace boundary and a swipe can
 * be dismiss-synced. Also sets the dismiss-action `category` and marks the
 * alert time-sensitive (the app holds that entitlement).
 */
export function buildApnsPayload(input: ApnsNotificationInput): Record<string, unknown> {
  if (input.kind === "dismiss") return buildDismissPayload(input);
  const hidden = input.hideContent === true;
  const title = hidden ? "cmux" : input.title.trim() || "cmux";
  const body = hidden ? "An agent needs your attention" : input.body;
  const subtitle = hidden ? undefined : input.subtitle?.trim() || undefined;

  const alert: Record<string, string> = { title };
  if (subtitle) alert.subtitle = subtitle;
  if (body) alert.body = body;

  const aps: Record<string, unknown> = {
    alert,
    sound: "default",
    "interruption-level": "time-sensitive",
    category: CMUX_APNS_CATEGORY,
  };
  if (typeof input.badgeCount === "number") aps.badge = input.badgeCount;

  const cmux: Record<string, string | boolean> = {};
  if (input.workspaceId) cmux.workspaceId = input.workspaceId;
  if (input.surfaceId) cmux.surfaceId = input.surfaceId;
  if (typeof input.retargetsToLiveSurfaceOwner === "boolean") {
    cmux.retargetsToLiveSurfaceOwner = input.retargetsToLiveSurfaceOwner;
  }
  if (input.macDeviceId) cmux.macDeviceId = input.macDeviceId;
  if (input.notificationId) cmux.notificationId = input.notificationId;

  return Object.keys(cmux).length > 0 ? { aps, cmux } : { aps };
}

/**
 * The Mac→iOS dismiss-sync push: no alert/sound/category (nothing visible),
 * `aps.badge` set to the authoritative unread total (applied by the system even
 * when iOS declines to wake the app), and `content-available: 1` so iOS wakes
 * the app — within its strictly budgeted background-push allowance — to remove
 * the dismissed delivered banners listed under `cmux.dismissedIds`.
 *
 * Deliberately sent as push-type `alert` with priority 5 (see sender): per
 * Apple's push-type taxonomy a badge update is user-facing, so this is not a
 * `background` push, and a `background` push may not carry `badge` at all.
 */
function buildDismissPayload(input: ApnsNotificationInput): Record<string, unknown> {
  const aps: Record<string, unknown> = { "content-available": 1 };
  if (typeof input.badgeCount === "number") aps.badge = input.badgeCount;
  return { aps, cmux: { dismissedIds: [...(input.dismissedIds ?? [])] } };
}

/**
 * Whether an APNs response means the token is permanently invalid and should be
 * deleted. 410 (Unregistered, with a timestamp) and the `BadDeviceToken` /
 * `DeviceTokenNotForTopic` / `Unregistered` reasons are terminal; transient
 * failures (timeouts, 5xx, connection errors with status 0) are not pruned.
 */
export function shouldPruneToken(status: number, reason: string | undefined): boolean {
  if (status === 410) return true;
  if (reason === "Unregistered") return true;
  if (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic")) {
    return true;
  }
  return false;
}
