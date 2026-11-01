//! Orchestrator tags on a chat, each with an optional expiry.

use super::*;

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
        self.child_tags.note(session);
        let saved = self.save_meta_answered(session);
        self.append(session, "mux", "tags", json!({"tags": live_tags(&session.meta())}));
        saved
    }
}
