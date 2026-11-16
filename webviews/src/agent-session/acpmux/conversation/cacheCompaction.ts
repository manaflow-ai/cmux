// acpmux's "Compact Before the Cache Expires" timer (cmux-tui hub/cache_compact.rs, Settings >
// Prompt Cache): it sends `/compact` as its own prompt, provenance kind `cache_compact`, never the
// person's. The pane draws no bubble for it, and that turn's compaction note says why it ran (Leo,
// 2026-11-12, on such a "/compact" in his chat: "i didnt send it myself", "we should not get into
// this state").

/// The compaction reason the pane gives a compaction the timer's prompt started (CompactionNote.tsx).
export const CACHE_EXPIRY_REASON = "cache_expiry";

/// Whether a prompt record is the timer's `/compact`: only its provenance decides, never the text,
/// which the person's own `/compact` shares.
export function isCacheCompaction(msg: { _meta?: { provenance?: unknown } } | undefined): boolean {
  return (msg?._meta?.provenance as { kind?: unknown } | undefined)?.kind === "cache_compact";
}
