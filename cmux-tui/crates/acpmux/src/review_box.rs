//! Whether a session is a review box: one `lane-place new --review` started (its harness ends with
//! `-review-box`, e.g. `codex-review-box`), or one carrying a `review.` tag (`review.verdict`). The
//! one test for it: `acpmux ls` hides these rows (`cli/ls_table.rs`), and the inbox takes no
//! message for one (`hub/inbox.rs`).

use crate::store::SessionMeta;

/// The harness name's ending that marks a review box.
const HARNESS_SUFFIX: &str = "-review-box";
/// The tag prefix that marks a review box.
const TAG_PREFIX: &str = "review.";

/// Whether a session with this harness and these tag keys is a review box.
pub fn is<'a>(harness: &str, mut tags: impl Iterator<Item = &'a str>) -> bool {
    harness.ends_with(HARNESS_SUFFIX) || tags.any(|k| k.starts_with(TAG_PREFIX))
}

/// [`is`] of a session's meta, its unexpired tags only (as `acpmux ls` shows them).
pub fn of_meta(meta: &SessionMeta) -> bool {
    let now = crate::store::now_ms();
    let live = meta
        .tags
        .iter()
        .filter(|(_, t)| t.expires_at.is_none_or(|e| e > now))
        .map(|(k, _)| k.as_str());
    is(&meta.harness, live)
}

#[cfg(test)]
mod tests;
