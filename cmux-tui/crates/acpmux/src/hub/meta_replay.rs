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
//! their expiry since this change), the permission policy (`policy`) and rules (`rules`), and the
//! person's read or unread mark (a `status` record with `read`, `seen.rs`). Each
//! is changed and logged in one step after the session is caught up (`Hub::change_logged`), so
//! the replay comes before a change made while a deferred start still reads the logs, never
//! over it, and the records are in the order of the changes.

use serde_json::Value;

use super::{Hub, Session};
use crate::no_panic::LockExt;
use crate::store::{EventRecord, SessionMeta, Tag};

impl Hub {
    /// Changes `session`'s settings with `change` and logs the record of `kind` it returns, as
    /// one step under the append lock. A restart rebuilds these settings from such records
    /// ([`apply`]), so:
    /// - the session is caught up first (`catch_up_locked`): the log records the restart
    ///   replays come before the change, never over it (a change answered while a deferred
    ///   start still reads the logs);
    /// - the record is built from the meta the change leaves, under the lock that orders the
    ///   log: two concurrent changes log in the order they changed the meta.
    ///
    /// `change` returning None logs nothing.
    pub(super) fn change_logged(
        &self,
        session: &Session,
        kind: &str,
        change: impl FnOnce(&mut SessionMeta) -> Option<Value>,
    ) -> Option<EventRecord> {
        let order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
        let msg = change(&mut session.meta.lock_or_recover())?;
        Some(self.append_locked(&order, session, "mux", kind, msg, None, None).0)
    }
}

/// The log record kinds [`apply`] reads.
pub(super) const KINDS: &[&str] = &["renamed", "titled", "tags", "policy", "rules", "status"];

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
            // As the live answer (`apply_generated_title`): a harness title or the person's
            // name wins over a generated one.
            let kept = matches!(
                meta.title_source.as_deref(),
                Some(super::titles::HARNESS | super::titles::NAMED)
            );
            if let Some(title) = msg.get("title").and_then(Value::as_str)
                && !kept
            {
                super::titles::title_generated(meta, title);
            }
        }
        // Only a record with its tags' expiry (`expires`, since this change) rebuilds them: an
        // older one would make a tag that expires (a trust wait's) last forever.
        "tags" => {
            if let Some(tags) = msg.get("tags").and_then(Value::as_object)
                && let Some(expires) = msg.get("expires").and_then(Value::as_object)
            {
                meta.tags = tags
                    .iter()
                    .map(|(k, v)| {
                        let value = v.as_str().map_or_else(|| v.to_string(), str::to_owned);
                        let expires_at = expires.get(k).and_then(Value::as_u64);
                        (k.clone(), Tag { value, expires_at })
                    })
                    .collect();
            }
        }
        "policy" => {
            meta.permission_policy = msg.get("policy").and_then(Value::as_str).map(str::to_owned);
        }
        "rules" => meta.permission_rules = msg.get("rules").cloned().filter(|r| !r.is_null()),
        // The person's read or unread mark (`seen.rs`); a status record without `read` (a turn's
        // status) changes nothing here.
        "status" => {
            if let Some(read) = msg.get("read").and_then(Value::as_bool) {
                meta.unread = !read;
            }
        }
        _ => {}
    }
}

#[cfg(test)]
#[path = "meta_replay_tests.rs"]
mod tests;
