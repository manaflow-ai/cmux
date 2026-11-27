//! First, default-off ask-ledger experiment. A prompt opts in at the client, but only the
//! daemon's proven human-send boundary may capture it. A bounded recent view lives for this
//! daemon run; the chat journal remains the durable source. No background scan or second file.
//! Purged chats are filtered through their own purge flag, including late accepted callbacks.

use super::{Hub, Session};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub(crate) const METHOD: &str = "_acpmux/ask_ledger";
const LIMIT: usize = 200;
const TEXT_CHARS: usize = 16_384;

#[derive(Default)]
pub(crate) struct AskLedger {
    rows: Mutex<VecDeque<(Value, Arc<AtomicBool>)>>,
}

impl AskLedger {
    fn capture(&self, entry: Value, purged: Arc<AtomicBool>) {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        rows.retain(|(_, gone)| !gone.load(Ordering::SeqCst));
        if purged.load(Ordering::SeqCst) || rows.iter().any(|(row, _)| row["id"] == entry["id"]) {
            return;
        }
        rows.push_front((entry, purged));
        rows.truncate(LIMIT);
    }

    /// The newest accepted asks only, never a scan of chats or their journals.
    pub(crate) fn page(&self) -> Value {
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        rows.retain(|(_, gone)| !gone.load(Ordering::SeqCst));
        json!({"entries": rows.iter().map(|(row, _)| row).collect::<Vec<_>>()})
    }
}

/// Full digest of a length-delimited tuple: stable across retries; neither text nor time is an id.
fn identity(harness: &str, session: &str, message: &str) -> String {
    let mut hash = Sha256::new();
    for part in [harness, session, message] {
        hash.update((part.len() as u64).to_be_bytes());
        hash.update(part.as_bytes());
    }
    format!("ask-{:x}", hash.finalize())
}

impl Hub {
    /// Adds capture to acceptance, never to a successful turn's eventual result. An unaccepted
    /// send writes nothing; a duplicate/withdrawn/resend receipt writes nothing. The original
    /// callback always runs, so this view cannot change the composer's accepted-send behavior.
    pub(crate) fn capture_ask_on_accept(
        self: &Arc<Self>,
        session: &Arc<Session>,
        text: &str,
        next: Option<Box<dyn FnOnce(Value) + Send>>,
    ) -> Option<Box<dyn FnOnce(Value) + Send>> {
        let hub = Arc::downgrade(self);
        let session_id = session.id.clone();
        let harness = session.read_meta(|m| m.harness.clone());
        let gone = session.purged.clone();
        let body: String = text.chars().take(TEXT_CHARS).collect();
        let truncated = body.len() < text.len();
        Some(Box::new(move |accepted| {
            let ignored = ["duplicate", "withdrawn", "resent"]
                .iter()
                .any(|key| accepted.get(key).and_then(Value::as_bool) == Some(true));
            if !ignored
                && !body.trim().is_empty()
                && let Some(message_id) = accepted.get("promptId").and_then(Value::as_str)
                && let Some(hub) = hub.upgrade()
            {
                hub.ask_ledger.capture(
                    json!({
                        "id": identity(&harness, &session_id, message_id),
                        "messageId": message_id,
                        "sessionId": session_id,
                        "harness": harness,
                        "host": crate::host_pressure::host_name(),
                        "text": body,
                        "truncated": truncated,
                        "createdAt": crate::store::now_ms(),
                    }),
                    gone,
                );
            }
            if let Some(next) = next {
                next(accepted);
            }
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ask_ledger_is_bounded_deduplicated_and_forgets_purged_chats() {
        let ledger = AskLedger::default();
        assert_eq!(ledger.page()["entries"], json!([]));
        let gone = Arc::new(AtomicBool::new(false));
        for n in 0..LIMIT + 10 {
            ledger.capture(json!({"id": n}), gone.clone());
        }
        ledger.capture(json!({"id": LIMIT + 9}), gone.clone());
        let page = ledger.page();
        let rows = page["entries"].as_array().unwrap();
        assert_eq!(rows.len(), LIMIT);
        assert_eq!(rows[0]["id"], LIMIT + 9);
        assert_eq!(rows[LIMIT - 1]["id"], 10);
        gone.store(true, Ordering::SeqCst);
        ledger.capture(json!({"id": "late"}), gone);
        assert_eq!(ledger.page()["entries"], json!([]));
    }

    #[test]
    fn ask_ledger_identity_is_stable_and_tuple_boundaries_matter() {
        assert_eq!(identity("claude", "a", "b"), identity("claude", "a", "b"));
        assert_ne!(identity("claude", "a", "bc"), identity("claude", "ab", "c"));
        assert_ne!(identity("claude", "a", "b"), identity("codex", "a", "b"));
    }
}
