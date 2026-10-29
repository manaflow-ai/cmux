//! A session's settings a client changed come back after a crash from the event log, the source
//! of truth (2026-10-29, the same bug class as trains 333 and 338's lost queue edit: an answered
//! change came back undone). The session record (`session.json`) is written by one background
//! thread (`meta_writer.rs`, with an fsync); a request does not wait for it (20-50 ms against
//! the 2 ms op budget). Each change also appends its record to the log, so at start the
//! settings are the saved record plus the log records after its `lastSeq`, applied in order
//! ([`apply`], from `Hub::catch_up`): a level rebuilt from one source, never an event replayed
//! twice into a different state (applying a record the saved record already holds sets the
//! same value again).
//!
//! The settings: the name (`renamed`), the generated title (`titled`), the tags (`tags`, with
//! their expiry since this change), the permission policy (`policy`) and rules (`rules`).

use serde_json::Value;

use crate::store::{EventRecord, SessionMeta, Tag};

/// The log record kinds [`apply`] reads.
pub(super) const KINDS: &[&str] = &["renamed", "titled", "tags", "policy", "rules"];

/// Applies `rec`, a record after the saved record's `lastSeq`, to `meta`.
pub(super) fn apply(meta: &mut SessionMeta, rec: &EventRecord) {
    let msg = &rec.msg;
    match rec.kind.as_str() {
        "renamed" => {
            if let Some(name) = msg.get("to").and_then(Value::as_str) {
                super::titles::title_renamed(meta);
                meta.name = name.to_owned();
            }
        }
        "titled" => {
            if let Some(title) = msg.get("title").and_then(Value::as_str) {
                super::titles::title_generated(meta, title);
            }
        }
        "tags" => {
            if let Some(tags) = msg.get("tags").and_then(Value::as_object) {
                let expires = msg.get("expires");
                meta.tags = tags
                    .iter()
                    .map(|(k, v)| {
                        let value = v.as_str().map_or_else(|| v.to_string(), str::to_owned);
                        let expires_at = expires.and_then(|e| e.get(k)).and_then(Value::as_u64);
                        (k.clone(), Tag { value, expires_at })
                    })
                    .collect();
            }
        }
        "policy" => {
            meta.permission_policy = msg.get("policy").and_then(Value::as_str).map(str::to_owned);
        }
        "rules" => meta.permission_rules = msg.get("rules").cloned().filter(|r| !r.is_null()),
        _ => {}
    }
}

#[cfg(test)]
#[path = "meta_replay_tests.rs"]
mod tests;
