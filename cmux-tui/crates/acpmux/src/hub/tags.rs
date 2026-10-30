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
        let expires_at = ttl_seconds.map(|t| now_ms().saturating_add(t.saturating_mul(1000)));
        self.change_logged(session, "tags", |m| {
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
            // With each tag's expiry, so a restart rebuilds the tags from this record
            // (`meta_replay.rs`).
            let expires: serde_json::Map<String, Value> = m
                .tags
                .iter()
                .filter_map(|(k, t)| t.expires_at.map(|at| (k.clone(), json!(at))))
                .collect();
            Some(json!({"tags": live_tags(m), "expires": expires}))
        });
        self.child_tags.note(session);
        self.save_meta(session);
    }
}
