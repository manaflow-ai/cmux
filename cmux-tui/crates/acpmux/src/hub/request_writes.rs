//! One rule for every acpmux request that changes state: **it answers only after what it wrote
//! is on disk.** Trains 333 and 338 (2026-10-29) lost an answered queue edit: the event log is
//! written by one background thread (`store/log_writer.rs`), and a daemon killed between the
//! answer and that write brought the old queue back.
//!
//! The request runner (`server/request_task.rs`) runs each request inside [`scope`] and, before
//! the answer goes out, [`Hub::wait_written`] waits until every event log record noted in it is
//! written: the noted sessions move to the front of the writer's turn (`LogWriter::expedite`),
//! then the request waits on the store's progress (the agent host's `WriteTicket`). Noted:
//! - every record the request appends on its own task (`Hub::append_at` calls [`note_log`]),
//!   which covers the records a transfer's import copied on a blocking thread before it: the
//!   import's `imported` record comes after them in the same log;
//! - the `permission_decision` record of a prompt it answers (`_acpmux/permission_respond`,
//!   `_acpmux/permission_group_respond`, an ancestor's answer): the task that asked appends it
//!   once the answer wakes it and sends its seq back (`PendingPermission::decision_seq`,
//!   [`note_decision`]); an asking task that is gone appended nothing, and nothing is waited for;
//! - a family prompt's records up to its acceptance, appended on the turn's own task
//!   (`send_family_prompt` calls [`note_session`]).
//!
//! A log that failed (an append on the request's task failed, [`note_failed`], or the store
//! reports the session's log failed) is not saved: the request answers an error with
//! `data.reason = "log.failed"` ([`answer`]), except `session/prompt` (its prompt ledger holds
//! the Ok already, and a retry would start a second turn) and `session/new` (the session exists),
//! which keep their Ok, marked `_meta.acpmux.saved = false`.
//!
//! Not waited for, by design:
//! - a session record (`session.json`, `meta_writer.rs`): its write syncs the file (20-50 ms on
//!   macOS) against the 2 ms op budget; what a restart needs from it is in the event log too
//!   (`renamed`, `tags`, `policy`...), and the log is the source of truth.
//! - a config file (`Hub::save_config`, `config_writer.rs`): its write syncs the file too, and a
//!   model, effort or mode pick saves one, against the same budget. A pick answered right before a
//!   crash can come back as the previous pick at the next start; the person picks it again.
//! - work a request hands to another task (a spawned turn past its acceptance, a supervised job,
//!   a blocking thread): it is not the request's answer. A handler whose answer depends on such
//!   an append notes it itself (`send_family_prompt`, above).
//! - a prompt's cancelled decision after a cancel (`cancel_pending_permissions`): a cancel is a
//!   notification or part of a turn's end, with no answer to hold.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::atomic::Ordering;

use futures::future::BoxFuture;
use serde_json::{Value, json};
use tokio::sync::oneshot;

use super::{Hub, Session};
use crate::rpc::{RpcError, method};

/// What one request wrote: the last record of each session's log, and whether an append failed.
#[derive(Debug, Default)]
pub(crate) struct Writes {
    logs: HashMap<String, u64>,
    failed: bool,
}

tokio::task_local! {
    static WRITES: RefCell<Writes>;
}

/// Runs `request` and returns its result with what it wrote. Takes the request boxed: a
/// handler's future is large, and only a pointer moves into the scope.
pub(crate) async fn scope<T>(request: BoxFuture<'_, T>) -> (T, Writes) {
    WRITES
        .scope(RefCell::new(Writes::default()), async {
            let result = request.await;
            let writes = WRITES.with(|w| std::mem::take(&mut *w.borrow_mut()));
            (result, writes)
        })
        .await
}

/// The request on this task appended record `seq` to session `id`'s log.
pub(crate) fn note_log(id: &str, seq: u64) {
    let _ = WRITES.try_with(|w| {
        let mut w = w.borrow_mut();
        let w = &mut *w;
        // Per append: no key allocated once the session is noted.
        if let Some(last) = w.logs.get_mut(id) {
            *last = (*last).max(seq);
        } else {
            w.logs.insert(id.to_owned(), seq);
        }
    });
}

/// The request on this task waits for every record `session` holds so far: records appended
/// for it on another task, up to a point this task saw (a family prompt's acceptance).
pub(crate) fn note_session(session: &Session) {
    note_log(&session.id, session.seq.load(Ordering::SeqCst));
}

/// An append on this task failed: what the request changed is not saved.
pub(crate) fn note_failed() {
    let _ = WRITES.try_with(|w| w.borrow_mut().failed = true);
}

/// Notes the decision record the task that asked appends for a prompt this request answered
/// (`PendingPermission::decision_seq`). That task sends the seq with no await after the answer
/// wakes it; one that is gone (aborted, dropped) appended nothing and closes the channel, so this
/// never waits on more than that task's next synchronous step.
pub(crate) async fn note_decision(id: &str, decision_seq: oneshot::Receiver<Option<u64>>) {
    match decision_seq.await {
        Ok(Some(seq)) => note_log(id, seq),
        Ok(None) => note_failed(),
        Err(_) => {}
    }
}

/// The answer to request `name` once `saved` says whether what it wrote is on disk.
pub(crate) fn answer(
    name: &str,
    result: Result<Value, RpcError>,
    saved: bool,
) -> Result<Value, RpcError> {
    if saved {
        return result;
    }
    // Kept: the prompt ledger holds a prompt's Ok (a retry would start a second turn), and a new
    // session exists. The client learns the log did not keep it.
    let keeps_ok = matches!(name, method::SESSION_PROMPT | method::SESSION_NEW);
    match result {
        Ok(mut value) if keeps_ok => {
            mark_not_saved(&mut value);
            Ok(value)
        }
        Ok(_) => Err(RpcError::internal("the chat's event log failed: this change is not saved")
            .with_data(json!({"reason": "log.failed"}))),
        Err(e) => Err(e),
    }
}

/// Sets `_meta.acpmux.saved = false` on an object result; any other result is left as it is.
fn mark_not_saved(value: &mut Value) {
    let Some(result) = value.as_object_mut() else { return };
    let Some(meta) = result.entry("_meta").or_insert_with(|| json!({})).as_object_mut() else {
        return;
    };
    if let Some(acpmux) = meta.entry("acpmux").or_insert_with(|| json!({})).as_object_mut() {
        acpmux.insert("saved".to_owned(), json!(false));
    }
}

impl Hub {
    /// Waits until what `writes` names is on disk; false when a log failed.
    pub(crate) async fn wait_written(&self, writes: Writes) -> bool {
        if writes.failed {
            return false;
        }
        // Every noted session goes first in the writer's turn before the request waits on any.
        for id in writes.logs.keys() {
            self.store.expedite(id);
        }
        let mut saved = true;
        for (id, seq) in writes.logs {
            let ticket = crate::agent::WriteTicket::new(seq, self.store.progress(&id));
            saved &= ticket.written().await;
        }
        saved
    }
}

#[cfg(test)]
#[path = "request_writes_tests.rs"]
mod tests;
