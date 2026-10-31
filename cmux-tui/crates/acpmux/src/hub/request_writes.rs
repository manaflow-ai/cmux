//! One rule for every acpmux request that changes state: **it answers only after what it wrote
//! is on disk.** Trains 333 and 338 (2026-10-29) lost an answered queue edit: the event log is
//! written by one background thread (`store/log_writer.rs`), and a daemon killed between the
//! answer and that write brought the old queue back.
//!
//! The request runner (`server/request_task.rs`) runs each request inside [`scope`] and, before
//! the answer goes out, [`Hub::wait_written`] waits until every event log record noted in it is
//! written: the noted sessions go in the writer's next batch, in arrival order
//! (`LogWriter::expedite`), then the request waits on the store's progress, the writer raised to
//! the request's QoS meanwhile (`Store::write_boost`). Noted:
//! - every record the request appends on its own task (`Hub::append_at` calls [`note_log`]),
//!   which covers the records a transfer's import copied on a blocking thread before it: the
//!   import's `imported` record comes after them in the same log;
//! - the `permission_decision` record of a prompt it answers (`_acpmux/permission_respond`,
//!   `_acpmux/permission_group_respond`, an ancestor's answer): the task that asked appends it
//!   once the answer wakes it and sends its seq back (`PendingPermission::decision_seq`,
//!   [`note_decision`]); an asking task that is gone appended nothing, and nothing is waited for;
//! - the records of a prompt a handler runs on a spawned task, up to its acceptance, which the
//!   handler notes itself with [`note_session`]: `send_family_prompt` (the receiving session),
//!   `start_session` (also the parent's `subsession` "started" record, appended at the
//!   acceptance) and `_acpmux/btw` (the side session).
//!
//! A log that failed (an append on the request's task failed, [`note_failed`], or the store
//! reports the session's log failed) is not saved, and the answer says so ([`answer`]): an error
//! with `data.reason = "log.failed"`, except for a request that committed work a retry would do
//! twice ([`note_kept`]: a prompt accepted, `Hub::run_prompt_joined`'s acceptance, and a session
//! created or forked, `Hub::new_session`, `Hub::fork`). That one keeps its Ok, marked
//! `_meta.acpmux.saved = false`, whatever its entrypoint (`session/prompt`, `_acpmux/steer`,
//! `session/new`, `_acpmux/dispatch`, `_acpmux/btw`, `session/fork`, the agent tools'
//! `start_session` and `send_message`).
//!
//! Not waited for, by design:
//! - a session record (`session.json`, `meta_writer.rs`): its write syncs the file (20-50 ms on
//!   macOS) against the 2 ms op budget; what a restart needs from it is in the event log too
//!   (`renamed`, `tags`, `policy`...), and the log is the source of truth.
//! - a config file (`Hub::save_config`, `config_writer.rs`): its write syncs the file too, and a
//!   model, effort or mode pick saves one, against the same budget. A pick answered right before a
//!   crash can come back as the previous pick at the next start; the person picks it again.
//! - bookkeeping a request logs beside its answer, run through [`unnoted`]: the seen mark
//!   (`seen.rs`: `_acpmux/attach` and `_acpmux/view` showing an unread chat). Those requests
//!   answer what they read; the mark is a side effect, and the chat switch does not wait for a
//!   log write. `_acpmux/markUnread` is the person's own change and waits for its record.
//! - work a request hands to another task (a spawned turn past its acceptance, a supervised job,
//!   a blocking thread): it is not the request's answer, except the prompts noted above.
//! - the records of a session deleted while the request waits: nothing of it is kept, so it
//!   counts as saved, not as a failed log.
//!
//! Known gaps, answered before the asking task appends its decision (a crash in that window
//! loses it, and the person may be asked again or the turn ends as cancelled anyway):
//! - a prompt's cancelled decision after `session/cancel` sent as a request, or `_acpmux/kill`
//!   (`cancel_pending_permissions`);
//! - a secret's answer (`submit_secret`, `secrets.rs`): the waiting task records it.
//!
//! Known gaps where the work is another task's, past the answer:
//! - an agent message held between a paused pair on the `send_message` path: the hold is
//!   recorded on the spawned prompt task (`subsessions.rs`), after the request answered;
//! - forum posts' urgent pushes (`forum.rs`), run in a JoinSet after the post is answered;
//! - `_acpmux/dispatch` and the task request (`requests.rs`, `requests/briefs.rs`): the brief
//!   ledger answers before the prompt is accepted.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::atomic::Ordering;

use futures::future::BoxFuture;
use serde_json::{Value, json};
use tokio::sync::oneshot;

use super::{Hub, Session};
use crate::no_panic::LockExt;
use crate::rpc::RpcError;

/// What one request wrote: the last record of each session's log, whether an append failed, and
/// whether it committed work a retry would do twice (a prompt accepted, a session made).
#[derive(Debug, Default)]
pub(crate) struct Writes {
    logs: HashMap<String, u64>,
    failed: bool,
    kept: bool,
}

impl Writes {
    /// The request committed work a retry would do twice: its Ok stands even when not saved.
    pub(crate) fn kept(&self) -> bool {
        self.kept
    }

    /// The last record of session `id`'s log this request waits for, if any.
    #[cfg(test)]
    pub(crate) fn noted(&self, id: &str) -> Option<u64> {
        self.logs.get(id).copied()
    }
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

/// The request on this task committed work a retry would do twice: a prompt accepted (started,
/// queued or steered in, with the prompt ledger holding its outcome) or a session created.
pub(crate) fn note_kept() {
    let _ = WRITES.try_with(|w| w.borrow_mut().kept = true);
}

/// Runs `bookkeeping` with what it appends not noted for the request on this task: a record that
/// tells the clients, not what the answer acknowledges (the seen mark, `seen.rs`).
pub(crate) fn unnoted<R>(bookkeeping: impl FnOnce() -> R) -> R {
    WRITES.sync_scope(RefCell::new(Writes::default()), bookkeeping)
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

/// The answer to a request once `saved` says whether what it wrote is on disk; `kept`: it
/// committed work a retry would do twice ([`Writes::kept`]).
pub(crate) fn answer(
    result: Result<Value, RpcError>,
    saved: bool,
    kept: bool,
) -> Result<Value, RpcError> {
    if saved {
        return result;
    }
    // Kept: the prompt ledger holds an accepted prompt's Ok (a retry would start a second turn),
    // and a new session exists. The client learns the log did not keep it.
    match result {
        Ok(mut value) if kept => {
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
    /// Runs one request under the rule (`server/request_task.rs` runs every request through it):
    /// its handler in [`scope`], then [`Hub::wait_written`] for what it wrote, then [`answer`].
    pub(crate) async fn answer_request(
        &self,
        request: BoxFuture<'_, Result<Value, RpcError>>,
    ) -> Result<Value, RpcError> {
        let (result, writes) = scope(request).await;
        let kept = writes.kept();
        // An error that committed records (a held agent message: "held, do not send it again")
        // waits for them too; its answer stays the error.
        let saved = self.wait_written(writes).await;
        answer(result, saved, kept)
    }

    /// Waits until what `writes` names is on disk; false when a log failed.
    pub(crate) async fn wait_written(&self, writes: Writes) -> bool {
        if writes.failed {
            return false;
        }
        // Every noted session goes in the writer's next batch before the request waits on any,
        // after the sessions earlier requests wait for (`store/log_writer.rs`).
        for id in writes.logs.keys() {
            self.store.expedite(id);
        }
        // The writer runs at this request's QoS until the wait ends (priority inheritance); a
        // request that wrote nothing waits for nothing and raises nothing.
        let boost = if writes.logs.is_empty() { None } else { self.store.write_boost() };
        let _raise = boost.as_deref().map(cmux_threads::OwnerBoost::wait);
        let mut saved = true;
        for (id, seq) in writes.logs {
            saved &= self.log_written(&id, seq).await;
        }
        saved
    }

    /// Waits until record `seq` of session `id`'s log is written; false when its log failed.
    async fn log_written(&self, id: &str, seq: u64) -> bool {
        // Deleted already: nothing of it is kept, and asking the writer for its progress would
        // make a new entry for a log it forgot.
        if self.deleted(id) {
            return true;
        }
        let Some(mut progress) = self.store.progress(id) else { return true };
        loop {
            let p = *progress.borrow_and_update();
            if p.failed {
                return false;
            }
            if p.covers(seq) {
                return true;
            }
            if progress.changed().await.is_err() {
                // The writer forgot the log (`LogWriter::forget`): its session was deleted while
                // the request waited, and nothing of it is kept. Any other close loses the record.
                let p = *progress.borrow();
                return p.covers(seq) || self.deleted(id);
            }
        }
    }

    /// Session `id` was deleted (purged), or is not this hub's any more.
    fn deleted(&self, id: &str) -> bool {
        self.sessions.lock_or_recover().get(id).is_none_or(|s| s.purged.load(Ordering::SeqCst))
    }
}

#[cfg(test)]
#[path = "request_writes_tests.rs"]
mod tests;
