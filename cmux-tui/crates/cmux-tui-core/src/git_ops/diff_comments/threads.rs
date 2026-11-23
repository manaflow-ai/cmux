//! Sent reviews as threads: what a send carried, under its acpmux prompt id,
//! and the agent's reply to that prompt once its turn ended.
//!
//! A send records its thread in the same locked write that clears the sent
//! comments ([`record`]). A list answers every thread with its reply
//! ([`answered`]): a thread whose reply is kept answers from the file; one
//! still open asks acpmux (`Mux::acp_turn_reply`) and, when the turn ended,
//! keeps the reply under the root's lock, so each turn is read from acpmux
//! once and a list of settled threads makes no acpmux call.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{File, MAX_THREADS, Store, io_failed};
use crate::Mux;
use crate::git_ops::checkpoint::record::{now_ms, rfc3339};
use crate::resource::ResourceError;
use crate::server::TurnReply;

/// One sent review.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Thread {
    /// The acpmux prompt id the review went as; the thread's id.
    pub(super) id: String,
    /// The acpmux session it went to.
    pub(super) acp_session: String,
    /// When acpmux took it: RFC 3339, and Unix ms for the reply search.
    pub(super) sent_at: String,
    pub(super) sent_ms: u64,
    /// The comments as they were sent, in store order.
    pub(super) comments: Vec<Map<String, Value>>,
    /// The agent's answer once its turn ended: `{status, text}`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) reply: Option<Value>,
}

/// Keeps the comments `ids` names, as they are now, as the thread of
/// `prompt_id`; the oldest threads go past [`MAX_THREADS`].
pub(super) fn record(file: &mut File, prompt_id: &str, acp_session: &str, ids: &[String]) {
    let comments: Vec<_> = file
        .comments
        .iter()
        .filter(|c| {
            c.get("id").and_then(Value::as_str).is_some_and(|id| ids.iter().any(|x| x == id))
        })
        .cloned()
        .collect();
    let now = now_ms();
    file.threads.retain(|thread| thread.id != prompt_id);
    file.threads.push(Thread {
        id: prompt_id.to_owned(),
        acp_session: acp_session.to_owned(),
        sent_at: rfc3339(now),
        sent_ms: now,
        comments,
        reply: None,
    });
    let excess = file.threads.len().saturating_sub(MAX_THREADS);
    file.threads.drain(..excess);
}

/// `threads` as a list answers them, each with its `reply`: kept, read now
/// from acpmux, `{status: "pending"}` while the turn runs or waits, or
/// `{status: "unknown"}` when acpmux could not say.
pub(super) fn answered(
    mux: &Arc<Mux>,
    store: &Store,
    root: &str,
    threads: Vec<Thread>,
    operation: &str,
) -> Result<Vec<Value>, ResourceError> {
    answered_with(store, root, threads, operation, |thread| {
        mux.acp_turn_reply(&thread.acp_session, &thread.id, thread.sent_ms)
    })
}

/// [`answered`] over any reply reader, for tests.
pub(super) fn answered_with(
    store: &Store,
    root: &str,
    mut threads: Vec<Thread>,
    operation: &str,
    read: impl Fn(&Thread) -> TurnReply,
) -> Result<Vec<Value>, ResourceError> {
    let mut settled = Vec::new();
    for thread in threads.iter_mut().filter(|thread| thread.reply.is_none()) {
        thread.reply = Some(match read(thread) {
            TurnReply::Ended { status, text } => {
                let reply = json!({"status": status, "text": text});
                settled.push((thread.id.clone(), reply.clone()));
                reply
            }
            TurnReply::Pending => json!({"status": "pending"}),
            TurnReply::Unreadable => json!({"status": "unknown"}),
        });
    }
    if !settled.is_empty() {
        keep(store, root, &settled).map_err(|error| io_failed(operation, &error))?;
    }
    Ok(threads.iter().map(|thread| serde_json::to_value(thread).unwrap_or(Value::Null)).collect())
}

/// Writes the ended replies into the root's file, under its lock.
fn keep(store: &Store, root: &str, settled: &[(String, Value)]) -> std::io::Result<()> {
    store.exclusive(root, || {
        let mut file = store.read(root)?;
        let mut changed = false;
        for thread in file.threads.iter_mut().filter(|thread| thread.reply.is_none()) {
            if let Some((_, reply)) = settled.iter().find(|(id, _)| *id == thread.id) {
                thread.reply = Some(reply.clone());
                changed = true;
            }
        }
        if changed { store.write(root, &file) } else { Ok(()) }
    })
}
