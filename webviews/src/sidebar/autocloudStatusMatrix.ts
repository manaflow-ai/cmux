/** The state and design axes covered by the AutoCloud status gallery matrix. */
export const AUTO_CLOUD_MATRIX_STATES = [
  "off",
  "synced",
  "syncing",
  "offline",
  "warming",
  "active",
  "here",
  "crowd",
] as const;

export const AUTO_CLOUD_MATRIX_DESIGNS = ["glyph", "pill", "split", "strip"] as const;
