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
 */
export const DOWNLOAD_URL =
  "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg";

export const DOWNLOAD_CONFIRMATION_PATH = "/download/confirmation";
