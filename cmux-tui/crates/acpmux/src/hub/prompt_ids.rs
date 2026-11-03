//! The client prompt ids a chat's log holds, so a prompt id is applied at most once whoever sends
//! it again and whether or not it says so.
//!
//! A client that lost its connection (a page reload, a socket the daemon swapped, a daemon
//! restart) cannot know whether its unanswered `session/prompt` was taken. The safe retry is the
//! same prompt under the same id. Before, the daemon read its log for that id only when the retry
//! set `_meta.acpmux.resend`; the in-memory ledger (`prompt_ledger.rs`) forgets ids after a
//! restart and past its 64 settled outcomes, so a retry without the flag ran the prompt twice.
//! The web pane cannot set the flag (only the Mac's prompt journal does), and remote chats have no
//! journal at all (HQ#6740: "Each prompt or steer carries a client-generated id. The daemon acks
//! on durable append. The client retries until acked, and the daemon dedupes by id").
//!
//! Now an id the log holds is read as a resend: `prompt_with` answers it from the log
//! (`logged_prompt`), a run that settled with its outcome and one still going by joining it. The
//! set of ids is read once per chat, on the first prompt that carries an id the ledger lacks, from
//! the records that name a prompt (the kinds of [`KINDS`]), and every later such record adds its
//! id as it is stored. A full read of the log happens only for an id the set holds, as for an
//! explicit resend before.

use super::{Hub, Session};
use crate::store::EventRecord;
use serde_json::Value;
use std::collections::HashSet;

/// The daemon's records that make a client prompt id taken: its prompt or steer (`user_message`),
/// a queued copy, an inbox message, and a Stop that names an accepted prompt before its
/// `user_message` (`prompt_ledger.rs`).
const KINDS: &[&str] = &["user_message", "queued", "inbox", "turn_stop_requested"];

/// The prompt id `record` takes, if it takes one.
fn taken_id(record: &EventRecord) -> Option<&str> {
    if record.dir != "mux" || !KINDS.contains(&record.kind.as_str()) {
        return None;
    }
    record.msg.get("promptId").and_then(Value::as_str).filter(|id| !id.is_empty())
}

impl Session {
    /// A record just stored (under `append_lock`): its prompt id is taken from now on. Nothing to
    /// do before the set is first read; that read sees the record.
    pub(super) fn note_logged_prompt(&self, record: &EventRecord) {
        let Some(id) = taken_id(record) else { return };
        let mut index = self.logged_prompt_ids.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(ids) = index.as_mut() {
            ids.insert(id.to_owned());
        }
    }
}

impl Hub {
    /// Whether the chat's log holds client prompt id `prompt_id` (a prompt, steer, queued copy,
    /// inbox message or Stop under it). A log that cannot be read answers true: the caller then
    /// reads it as a resend does, which finds nothing and runs the prompt, as before.
    pub(super) fn prompt_id_logged(&self, session: &Session, prompt_id: &str) -> bool {
        // The append lock orders this read with appends: a record stored while the set is read
        // is either in the read or noted after it (`note_logged_prompt`).
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut index = session.logged_prompt_ids.lock().unwrap_or_else(|e| e.into_inner());
        if index.is_none() {
            let mut ids = HashSet::new();
            let scanned = self.store.scan_kinds(&session.id, KINDS, &mut |record: EventRecord| {
                if let Some(id) = taken_id(&record) {
                    ids.insert(id.to_owned());
                }
                true
            });
            if let Err(error) = scanned {
                tracing::warn!(session = %session.id, %error, "cannot read the chat's prompt ids");
                return true;
            }
            *index = Some(ids);
        }
        index.as_ref().is_some_and(|ids| ids.contains(prompt_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{MemoryStore, SessionMeta};
    use serde_json::json;

    fn meta(id: &str) -> SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": "ids", "harness": "codex",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        }))
        .unwrap()
    }

    #[tokio::test]
    async fn an_id_is_taken_once_its_record_is_stored_before_or_after_the_first_read() {
        let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
        let session = hub.insert_test_session(meta("chat"));
        hub.append(&session, "mux", "user_message", json!({"text": "a", "promptId": "before"}));
        // An agent's record of any kind never takes an id.
        hub.append(&session, "in", "queued", json!({"promptId": "from-agent"}));
        assert!(hub.prompt_id_logged(&session, "before"));
        assert!(!hub.prompt_id_logged(&session, "after"));
        hub.append(&session, "mux", "queued", json!({"text": "b", "promptId": "after"}));
        assert!(hub.prompt_id_logged(&session, "after"));
        assert!(!hub.prompt_id_logged(&session, "from-agent"));
        assert!(!hub.prompt_id_logged(&session, ""));
    }
}
