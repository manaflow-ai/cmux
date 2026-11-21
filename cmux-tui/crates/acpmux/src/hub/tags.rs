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
        {
            let mut m = session.meta.lock().unwrap();
            let expires_at = ttl_seconds.map(|t| now_ms().saturating_add(t.saturating_mul(1000)));
            if let Some(set) = set {
                for (k, v) in set {
                    let value = match v {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    };
                    m.tags.insert(k.clone(), crate::store::Tag { value, expires_at });
                }
            }
            for k in remove {
                m.tags.remove(k);
            }
        }
        self.tags_changed_answered(session)
    }

    /// Preserve the original archive time when a caller retries or two clients archive together.
    pub(crate) fn set_archived_answered(
        &self,
        session: &Session,
        archived: bool,
    ) -> Result<(), RpcError> {
        const ARCHIVED: &str = "archived";
        let changed = {
            let mut meta = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let now = now_ms();
            if archived {
                let active = meta.tags.get(ARCHIVED).is_some_and(|tag| {
                    !tag.value.is_empty() && tag.expires_at.is_none_or(|expiry| expiry > now)
                });
                if !active {
                    meta.tags.insert(
                        ARCHIVED.into(),
                        crate::store::Tag { value: now.to_string(), expires_at: None },
                    );
                }
                !active
            } else {
                meta.tags.remove(ARCHIVED).is_some()
            }
        };
        if changed {
            self.tags_changed_answered(session)
        } else {
            // A previous persistence attempt may have failed after updating memory.
            self.save_meta_answered(session)
        }
    }

    fn tags_changed_answered(&self, session: &Session) -> Result<(), RpcError> {
        self.child_tags.note(session);
        self.lane_tags_changed(session);
        // The line first, then the metadata: with the event journal, a crash keeps records as a
        // prefix in that order, so the tag is never saved without its line (R-DURABILITY S3b).
        self.append(session, "mux", "tags", json!({"tags": live_tags(&session.meta())}));
        self.save_meta_answered(session)
    }
}

#[cfg(test)]
#[path = "meta_line_order_tests.rs"]
mod meta_line_order_tests;
