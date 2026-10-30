/** Stable download URL for the newest classic cmux NIGHTLY DMG (rolling `nightly` release). */
export const CMUX_NIGHTLY_DMG_URL =
  "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg";

/**
 * Stable download URL for the newest cmux NEXT NIGHTLY DMG.
 *
 * The rolling `nightly-next` release re-uploads this Apple silicon asset on
 * every feat-cmux-next nightly build. Its older `cmux-nightly-next-macos.dmg`
 * and universal/x86_64 assets stopped updating, so do not link those.
 */
export const CMUX_NEXT_NIGHTLY_DMG_URL =
  "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/cmux-nightly-next-macos-arm64.dmg";
