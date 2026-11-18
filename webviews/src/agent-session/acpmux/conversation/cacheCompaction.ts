// acpmux's "Compact Before the Cache Expires" timer (cmux-tui hub/cache_compact.rs, Settings >
// Prompt Cache): it sends `/compact` as its own prompt, provenance kind `cache_compact`, never the
// person's. The pane draws no bubble for it, and that turn's compaction note says why it ran (Leo,
// 2026-11-12, on such a "/compact" in his chat: "i didnt send it myself", "we should not get into
// this state").
//
// Its "When You Return" mode compacts once the cache expired, before the person's next prompt (the
// composer's Compact chip, composer/cacheCompactChipModel.ts): the same `/compact`, provenance kind
// `return_compact`, which takes the turn first while the person's prompt queues behind it.

/// The compaction reason the pane gives a compaction the timer's prompt started (CompactionNote.tsx).
export const CACHE_EXPIRY_REASON = "cache_expiry";
/// The reason for the one acpmux ran before the person's prompt, the cache having expired.
export const CACHE_RETURN_REASON = "cache_return";

export type CacheCompactionReason = typeof CACHE_EXPIRY_REASON | typeof CACHE_RETURN_REASON;

/// The reason a prompt record's `/compact` gives its compaction when acpmux sent it for the prompt
/// cache, else undefined: only its provenance decides, never the text, which the person's own
/// `/compact` shares.
export function cacheCompactionReason(
  msg: { _meta?: { provenance?: unknown } } | undefined,
): CacheCompactionReason | undefined {
  const kind = (msg?._meta?.provenance as { kind?: unknown } | undefined)?.kind;
  return kind === "cache_compact" ? CACHE_EXPIRY_REASON : kind === "return_compact" ? CACHE_RETURN_REASON : undefined;
}

/// Whether a prompt record is one of acpmux's cache `/compact`s (the timer's or the return's).
export function isCacheCompaction(msg: { _meta?: { provenance?: unknown } } | undefined): boolean {
  return cacheCompactionReason(msg) !== undefined;
}
