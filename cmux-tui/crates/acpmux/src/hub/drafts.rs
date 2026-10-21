//! Part of `Hub`; see `hub/mod.rs`. A chat's unsent composer draft.

use super::SessionMeta;

/// The unsent draft went out as `text`, from whichever client sent it: it is no longer the
/// chat's draft. Any other prompt leaves the draft as it is.
pub(super) fn clear_sent_draft(meta: &mut SessionMeta, text: &str) {
    if meta.composer_draft.as_deref().is_some_and(|d| d.trim() == text.trim()) {
        meta.composer_draft = None;
    }
}
