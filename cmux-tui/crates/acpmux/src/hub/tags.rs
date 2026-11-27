//! Orchestrator tags on a chat, each with an optional expiry.

use super::*;

// What ends a lane's report link, a tag change among them.
#[path = "lane_detach.rs"]
mod lane_detach;

impl Hub {
    /// Orchestrator tags with optional expiry.
    pub fn set_tags(
        &self,
        session: &Session,
        set: Option<&serde_json::Map<String, Value>>,
        remove: &[String],
        ttl_seconds: Option<u64>,
    ) {
        // A failed save is logged there; no request waits for this one.
        let _ = self.set_tags_answered(session, set, remove, ttl_seconds);
    }

    /// [`Hub::set_tags`] for `_acpmux/tag` and `_acpmux/archive`: answered only once the tags
    /// are saved (`meta_save.rs`).
    pub(crate) fn set_tags_answered(
        &self,
        session: &Session,
        set: Option<&serde_json::Map<String, Value>>,
        remove: &[String],
        ttl_seconds: Option<u64>,
    ) -> Result<(), RpcError> {
        let change = (set.cloned().unwrap_or_default(), remove.to_vec());
        self.update_tags_answered(session, |_| Some(change), ttl_seconds).map(|_| ())
    }

    /// [`Hub::set_tags_answered`] with the tags `change` picks from the chat's metadata, read
    /// under the same lock the tags are written under: a change that lands between a read and a
    /// write cannot be undone by it. `change` answers None to leave the tags alone; answers
    /// whether it changed them.
    pub(crate) fn update_tags_answered(
        &self,
        session: &Session,
        change: impl FnOnce(
            &crate::store::SessionMeta,
        ) -> Option<(serde_json::Map<String, Value>, Vec<String>)>,
        ttl_seconds: Option<u64>,
    ) -> Result<bool, RpcError> {
        {
            let mut m = session.meta.lock().unwrap();
            let Some((set, remove)) = change(&m) else {
                return Ok(false);
            };
            // The automatic archive's marker describes that archive only: any other change of
            // `archived` (an unarchive, an archive by hand, a `_acpmux/tag` write) drops it
            // (`inactive_archive.rs`).
            use super::inactive_archive::{ARCHIVED_BY_TAG, ARCHIVED_TAG};
            let drops_marker = (set.contains_key(ARCHIVED_TAG)
                || remove.iter().any(|k| k == ARCHIVED_TAG))
                && !set.contains_key(ARCHIVED_BY_TAG);
            let expires_at = ttl_seconds.map(|t| now_ms().saturating_add(t.saturating_mul(1000)));
            for (k, v) in set {
                let value = match v {
                    Value::String(s) => s,
                    other => other.to_string(),
                };
                m.tags.insert(k, crate::store::Tag { value, expires_at });
            }
            for k in &remove {
                m.tags.remove(k);
            }
            if drops_marker {
                m.tags.remove(ARCHIVED_BY_TAG);
            }
            // A deleted chat is an archived one (`history_delete.rs`): unarchived from any list,
            // it is restored, never purged later.
            if remove.iter().any(|k| k == ARCHIVED_TAG) && !sets(ARCHIVED_TAG) {
                use super::history_delete::{DELETED_BY_TAG, DELETED_TAG};
                m.tags.remove(DELETED_TAG);
                m.tags.remove(DELETED_BY_TAG);
            }
        }
        self.child_tags.note(session);
        self.lane_tags_changed(session);
        super::hybrid_hold::tags_changed();
        // The line first, then the metadata: with the event journal, a crash keeps records as a
        // prefix in that order, so the tag is never saved without its line (R-DURABILITY S3b).
        self.append(session, "mux", "tags", json!({"tags": live_tags(&session.meta())}));
        self.save_meta_answered(session).map(|_| true)
    }
}

#[cfg(test)]
#[path = "meta_line_order_tests.rs"]
mod meta_line_order_tests;
