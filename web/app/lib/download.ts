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
