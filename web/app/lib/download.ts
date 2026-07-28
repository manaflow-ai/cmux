/**
 * Single source of truth for cmux download links.
 *
 * `DOWNLOAD_URL` is the actual release asset. cmux ships only a macOS build,
 * so there is one asset; if win/linux builds are added later, route them from
 * here (and from the confirmation page) rather than duplicating URLs at call
 * sites.
 *
 * `DOWNLOAD_CONFIRMATION_PATH` is the locale-agnostic in-app route that every
 * Download CTA navigates to (same-tab). That page auto-triggers the real
 * download on mount, which avoids opening a new tab/popup (which browsers can
 * block, interrupting the download).
 *
 * `DOWNLOAD_CONFIRMATION_HREF` is what the CTAs actually link to: the
 * confirmation path plus a `dl=1` intent marker. The confirmation page only
 * auto-downloads when that marker is present and then strips it, so refreshing
 * or navigating back to the page does not re-trigger the download. Using a URL
 * marker (instead of the Performance navigation `type`) is correct for
 * client-side `Link` transitions, where the document navigation type still
 * reflects the original page load.
 */
export const DOWNLOAD_URL =
  "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg";

export const DOWNLOAD_CONFIRMATION_PATH = "/download/confirmation";

/** Query-param marker that signals the confirmation page to auto-download. */
export const DOWNLOAD_INTENT_PARAM = "dl";

export const DOWNLOAD_CONFIRMATION_HREF = `${DOWNLOAD_CONFIRMATION_PATH}?${DOWNLOAD_INTENT_PARAM}=1`;

/**
 * Platforms shown in the Download button's platform picker, besides macOS
 * (which is the button's primary action) and iOS (which links out to the
 * Founders Edition). These have no build yet, so picking one opens the
 * waitlist dialog.
 */
export const WAITLIST_PLATFORMS = ["linux", "android", "windows"] as const;

export type WaitlistPlatform = (typeof WAITLIST_PLATFORMS)[number];

/**
 * What a waitlist signup is for: a specific platform (from the platform menu)
 * or `"any"` (the generic "Join waitlist" entry points, which record interest
 * across every unreleased platform).
 */
export type WaitlistTarget = WaitlistPlatform | "any";

/**
 * PostHog Early Access Feature flag keys (project 244066, stage "concept")
 * backing each platform waitlist. Joining enrolls the identified person in the
 * matching feature, so signups show up as that feature's enrollees in PostHog
 * rather than only as a raw event.
 */
export const WAITLIST_EARLY_ACCESS_FLAGS: Record<WaitlistPlatform, string> = {
  linux: "cmux-for-linux",
  android: "cmux-for-android",
  windows: "cmux-for-windows",
};
