//! Part of `Hub`; see `hub/mod.rs`. A chat's unsent composer draft.

use super::{Hub, Session, SessionMeta, now_ms, queue};

impl Hub {
    /// The largest composer draft the daemon will persist for one session.
    pub const MAX_COMPOSER_DRAFT_CHARS: usize = 1_000_000;
    /// Generations cross JavaScript clients, so they must be exactly representable there.
    pub const MAX_COMPOSER_DRAFT_GENERATION: u64 = (1_u64 << 53) - 1;

    /// Ordinary edits share a generation. Clear, send and intentional replacement start a
    /// newer one on the client; an empty write never increments it again here. Unversioned
    /// clients use generation zero and must upgrade once this draft has advanced.
    pub fn set_composer_draft(
        &self,
        session: &Session,
        text: &str,
        generation: u64,
    ) -> Result<Option<String>, String> {
        if generation > Self::MAX_COMPOSER_DRAFT_GENERATION {
            return Err("composer draft generation must be a nonnegative safe integer".into());
        }
        if text.chars().count() > Self::MAX_COMPOSER_DRAFT_CHARS {
            return Err(format!(
                "composer draft exceeds {} characters",
                Self::MAX_COMPOSER_DRAFT_CHARS
            ));
        }
        if session.moving().is_some() {
            return Err(queue::moving_error().message);
        }
        let draft = (!text.trim().is_empty()).then(|| text.to_owned());
        {
            let mut meta = session.meta.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if generation < meta.composer_draft_generation {
                return Err(format!(
                    "stale composer draft generation {generation}; current generation is {} (unversioned writes use generation 0)",
                    meta.composer_draft_generation
                ));
            }
            // At the safe-integer limit a clear is terminal: never wrap or let an old write
            // reuse its generation. This also covers a daemon-initiated send at the limit.
            if generation == Self::MAX_COMPOSER_DRAFT_GENERATION
                && meta.composer_draft_generation == generation
                && meta.composer_draft.is_none()
                && draft.is_some()
            {
                return Err("composer draft generation exhausted".into());
            }
            meta.composer_draft = draft.clone();
            meta.composer_draft_generation = generation;
            meta.updated_at = now_ms();
        }
        self.save_meta_result(session).map_err(|e| format!("save composer draft failed: {e}"))?;
        Ok(draft)
    }
}

/// The unsent draft went out as `text`, from whichever client sent it: it is no longer the
/// chat's draft. Any other prompt leaves the draft as it is. If the web client already
/// cleared it, there is nothing to advance; its explicit clear may arrive before or after us.
/// Returns whether the caller must persist a new tombstone before dispatching the prompt.
pub(super) fn clear_sent_draft(meta: &mut SessionMeta, text: &str) -> bool {
    if meta.composer_draft.as_deref().is_some_and(|d| d.trim() == text.trim()) {
        meta.composer_draft = None;
        meta.composer_draft_generation = meta
            .composer_draft_generation
            .saturating_add(1)
            .min(Hub::MAX_COMPOSER_DRAFT_GENERATION);
        return true;
    }
    false
}
