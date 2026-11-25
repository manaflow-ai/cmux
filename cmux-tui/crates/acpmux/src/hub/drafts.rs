//! Part of `Hub`; see `hub/mod.rs`. A chat's unsent composer draft.

use super::SessionMeta;

/// The unsent draft went out as `text`, from whichever client sent it: it is no longer the
/// chat's draft. Any other prompt leaves the draft as it is.
/// True when it cleared one: the clear is an edit of the synced `draft/<id>` (`hub/synced.rs`).
pub(super) fn clear_sent_draft(meta: &mut SessionMeta, text: &str) -> bool {
    if meta.composer_draft.as_deref().is_some_and(|d| d.trim() == text.trim()) {
        meta.composer_draft = None;
        return true;
    }
    false
}
