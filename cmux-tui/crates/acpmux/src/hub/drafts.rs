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
        let draft = (!is_ecmascript_blank(text)).then(|| text.to_owned());
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
    if meta.composer_draft.as_deref().is_some_and(|d| {
        !is_ecmascript_blank(d) && !is_ecmascript_blank(text) && d.trim() == text.trim()
    }) {
        meta.composer_draft = None;
        meta.composer_draft_generation = meta
            .composer_draft_generation
            .saturating_add(1)
            .min(Hub::MAX_COMPOSER_DRAFT_GENERATION);
        return true;
    }
    false
}

/// The ECMAScript WhiteSpace plus LineTerminator set used by the webview's draft layer.
/// In particular, U+0085 is text and U+FEFF is blank; Rust's Unicode `trim` differs here.
fn is_ecmascript_blank(text: &str) -> bool {
    text.chars().all(|character| matches!(
        character,
        '\u{0009}'..='\u{000D}'
            | '\u{0020}'
            | '\u{00A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
            | '\u{FEFF}'
    ))
}

/// Restores the draft around a failed send only while the failed send's tombstone is still
/// present. A concurrent `draft_set` changes either the text or generation and must win.
pub(super) fn restore_after_failed_send(
    meta: &mut SessionMeta,
    before: &(Option<String>, u64),
    tombstone: &(Option<String>, u64),
) {
    if failed_send_tombstone_matches(
        meta.composer_draft.as_deref(),
        meta.composer_draft_generation,
        tombstone.0.as_deref(),
        tombstone.1,
    ) {
        meta.composer_draft = before.0.clone();
        meta.composer_draft_generation = before.1;
    }
}

fn failed_send_tombstone_matches(
    current_draft: Option<&str>,
    current_generation: u64,
    tombstone_draft: Option<&str>,
    tombstone_generation: u64,
) -> bool {
    current_draft == tombstone_draft && current_generation == tombstone_generation
}

#[cfg(test)]
mod tests {
    #[test]
    fn draft_blank_matches_ecmascript_whitespace() {
        for (text, blank) in [
            ("", true),
            ("\u{0085}", false),
            ("\u{FEFF}", true),
            ("\u{00A0}", true),
            ("\u{2028}", true),
            (" \u{0085} ", false),
            ("text\u{00A0}", false),
        ] {
            assert_eq!(super::is_ecmascript_blank(text), blank, "U+{:04X}", text.chars().next().unwrap_or('\0') as u32);
        }
    }

    #[test]
    fn failed_send_tombstone_matches_only_its_empty_generation() {
        assert!(super::failed_send_tombstone_matches(None, 4, None, 4));
        assert!(!super::failed_send_tombstone_matches(Some("new edit"), 5, None, 4));
        assert!(!super::failed_send_tombstone_matches(None, 5, None, 4));
    }
}
