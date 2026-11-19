// The composer's cache chip beside Send (CacheCompactChip.tsx): once a big Claude chat's prompt
// cache has expired, acpmux ("When You Return", Settings > Prompt Cache) compacts it before the
// person's next prompt, which would otherwise read the whole context again uncached. The chip
// shows that ("Compact · 312K"); a click flips it to Keep (send cold, no compaction) and back.
// acpmux decides and runs the compaction; the composer only mirrors its flag (usage
// `compactOnReturn`) and passes the per-send choice (`session/prompt` `_meta.acpmux.cacheCompact`).
// React-free: the client (direct.ts) and tests read it too.

/// What a send asks acpmux: "compact" first, then send; or "keep": send as is.
export type CacheCompactChoice = "compact" | "keep";

export type CacheCompactChipState = {
  /// The latest usage report's: acpmux will compact before the next prompt once the cache expired.
  compactOnReturn?: boolean;
  /// When the prompt cache lapses (unix ms).
  cacheExpiresAt?: number;
  /// The cache has lapsed by the composer's clock (useCacheTimeLeft reached 0).
  expired: boolean;
  /// No turn runs (a prompt now starts one rather than queueing or steering).
  idle: boolean;
  /// The composer holds something to send.
  hasText: boolean;
};

/// Whether the chip shows: acpmux will compact on return, the cache it reported has expired, the
/// chat is idle and the composer has something to send.
export function cacheCompactChipShown(state: CacheCompactChipState): boolean {
  return (
    state.compactOnReturn === true && state.cacheExpiresAt !== undefined && state.expired && state.idle && state.hasText
  );
}

/// A click on the chip: Compact becomes Keep, Keep becomes Compact.
export function toggleCacheCompact(choice: CacheCompactChoice): CacheCompactChoice {
  return choice === "compact" ? "keep" : "compact";
}

/// What the send carries as `_meta.acpmux.cacheCompact`: the chip's choice while it shows, nothing
/// without it (acpmux then decides from the setting).
export function cacheCompactMeta(shown: boolean, choice: CacheCompactChoice): CacheCompactChoice | undefined {
  return shown ? choice : undefined;
}
