/** Stable download URL for the newest classic cmux NIGHTLY DMG (rolling `nightly` release). */
export const CMUX_NIGHTLY_DMG_URL =
  "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg";

/**
 * The update feed every cmux NEXT NIGHTLY app reads. The newest item is the
 * build the app offers as an update.
 */
export const CMUX_NEXT_NIGHTLY_FEED_URL =
  "https://files-next.cmux.com/nightly-next/appcast-arm64.xml";

/**
 * The cmux.com route every cmux NEXT download link uses. It redirects to the
 * DMG of the update feed's newest item, so a fresh download is the build the
 * app would update to, never the one before it.
 */
export const CMUX_NEXT_DOWNLOAD_PATH = "/api/download/next";

/**
 * The rolling `nightly-next` release asset: the route's fallback when the feed
 * cannot be read.
 *
 * A separate, later job moves this name, so it can trail the feed by a build
 * (it sat two hours behind on Nov 20). Link `CMUX_NEXT_DOWNLOAD_PATH` instead.
 */
export const CMUX_NEXT_NIGHTLY_DMG_URL =
  "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/cmux-nightly-next-macos-arm64.dmg";
