/**
 * Single source of truth for cmux download links.
 *
 * `DOWNLOAD_URL` is the native macOS terminal release asset. Windows and Linux
 * ship the cross-platform cmux Browser workspace instead; their stable website
 * endpoints are kept in `PLATFORM_DOWNLOADS` so landing pages, menus, and tests
 * share the same URLs. Those server-side endpoints verify cmux Browser's signed
 * nightly update feed before redirecting to an allowlisted public release asset.
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

/** Public repository that owns cmux Browser binaries and corresponding source. */
export const BROWSER_RELEASE_REPOSITORY_URL =
  "https://github.com/manaflow-ai/cmux-v2";

/** Stable page for the moving nightly release channel. */
export const BROWSER_NIGHTLY_RELEASE_URL =
  `${BROWSER_RELEASE_REPOSITORY_URL}/releases/tag/nightly`;

/** Discoverable landing page for the cross-platform cmux Browser nightly. */
export const BROWSER_NIGHTLY_PAGE = "/browser";

const BROWSER_NIGHTLY_DOWNLOAD_PATH = "/api/download/browser-nightly";

/** Universal 2 macOS artifacts resolved through the signed public feed. */
export const BROWSER_MACOS_NIGHTLY_DOWNLOAD = {
  primary: {
    artifact: "dmg",
    url: `${BROWSER_NIGHTLY_DOWNLOAD_PATH}/mac-arm64/dmg`,
  },
  secondary: {
    artifact: "update-zip",
    url: `${BROWSER_NIGHTLY_DOWNLOAD_PATH}/mac-arm64/zip`,
  },
} as const;

/** Flip only after the signed public feed and Universal 2 DMG are live. */
export const BROWSER_MACOS_NIGHTLY_AVAILABLE = false;

/**
 * Stable cross-platform cmux Browser download endpoints. The browser never
 * receives a private source-repository URL or a version hard-coded into the
 * website. The endpoint resolves the current signed public feed and can follow
 * either today's moving `nightly` tag or a future immutable
 * `nightly-<version>` tag.
 */
export const PLATFORM_DOWNLOADS = {
  windows: {
    page: "/windows",
    primary: {
      artifact: "installer",
      url: `${BROWSER_NIGHTLY_DOWNLOAD_PATH}/windows-x64/installer`,
    },
    secondary: {
      artifact: "portable-zip",
      url: `${BROWSER_NIGHTLY_DOWNLOAD_PATH}/windows-x64/zip`,
    },
  },
  linux: {
    page: "/linux",
    primary: {
      artifact: "run-installer",
      url: `${BROWSER_NIGHTLY_DOWNLOAD_PATH}/linux-x64/run`,
    },
    secondary: {
      artifact: "deb",
      url: `${BROWSER_NIGHTLY_DOWNLOAD_PATH}/linux-x64/deb`,
    },
  },
} as const;

export type DownloadPlatform = keyof typeof PLATFORM_DOWNLOADS;
export type PlatformDownloadAvailability = Readonly<
  Record<DownloadPlatform, boolean>
>;

/**
 * Release availability is deliberately separate from the stable URL contract.
 * Flip a platform only after every referenced artifact is present on the
 * latest public release. Until then its route, sitemap entry, and direct menu
 * link stay gated together.
 */
export const PLATFORM_DOWNLOAD_AVAILABILITY = {
  windows: false,
  linux: true,
} as const satisfies PlatformDownloadAvailability;

const DOWNLOAD_PLATFORM_ORDER = ["windows", "linux"] as const;
const WAITLIST_PLATFORM_ORDER = ["linux", "android", "windows"] as const;

/** Returns whether every public artifact required by a platform is released. */
export function isPlatformDownloadAvailable(
  platform: DownloadPlatform,
): boolean {
  return PLATFORM_DOWNLOAD_AVAILABILITY[platform];
}

export type WaitlistPlatform = (typeof WAITLIST_PLATFORM_ORDER)[number];

/**
 * Derives the Download menu's direct links and waitlist entries from one
 * release state, including mixed Windows-only or Linux-only releases.
 */
export function platformMenuSectionsForAvailability(
  availability: PlatformDownloadAvailability,
) {
  return {
    downloads: DOWNLOAD_PLATFORM_ORDER.filter(
      (platform) => availability[platform],
    ),
    waitlist: WAITLIST_PLATFORM_ORDER.filter(
      (platform) => platform === "android" || !availability[platform],
    ),
  };
}

const platformMenuSections = platformMenuSectionsForAvailability(
  PLATFORM_DOWNLOAD_AVAILABILITY,
);

/** Published platforms shown as direct page links in the Download menu. */
export const DOWNLOAD_PLATFORMS = platformMenuSections.downloads;

/** Unreleased platforms shown in the Download button's waitlist section. */
export const WAITLIST_PLATFORMS = platformMenuSections.waitlist;

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
