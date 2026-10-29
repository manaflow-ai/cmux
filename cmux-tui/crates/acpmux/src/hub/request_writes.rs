//! One rule for every acpmux request that changes state: **it answers only after what it wrote
//! is on disk.** Trains 333 and 338 (2026-10-29) lost an answered queue edit: the event log is
//! written by one background thread (`store/log_writer.rs`), and a daemon killed between the
//! answer and that write brought the old queue back.
//!
//! The request runner (`server/request_task.rs`) runs each request inside [`scope`]. Every log
//! record the request appends on its own task ([`note_log`], from `Hub::append_at` and a
//! transfer's import) and every config file it queues ([`note_config`], from
//! `Hub::save_config`) is noted; before the answer goes out, [`Hub::wait_written`] waits until
//! those records are written (the agent host's `WriteTicket` on the store's progress, with the
//! session moved to the front of the writer's turn) and the config writer has written what was
//! queued. A log that failed answers an error instead of a change that is not saved.
//!
//! Not covered, by design: a session record (`session.json`, `meta_writer.rs`) a request saves
//! is not waited for (its write syncs the file, 20-50 ms on macOS, against the 2 ms op budget);
//! what it holds that a restart needs is in the event log too (`renamed`, `tags`, `policy`...),
//! and the log is the source of truth. Work a request hands to another task (a spawned turn, a
//! supervised job) is not the request's answer and is not waited for.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use super::Hub;

/// What one request wrote: the last record of each session's log, and whether it queued a
/// config file.
#[derive(Debug, Default)]
pub(crate) struct Writes {
    logs: HashMap<String, u64>,
    config: bool,
}

tokio::task_local! {
    static WRITES: RefCell<Writes>;
}

/// Runs `request` and returns its result with what it wrote.
pub(crate) async fn scope<T>(request: impl std::future::Future<Output = T>) -> (T, Writes) {
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
        let last = w.logs.entry(id.to_owned()).or_default();
        *last = (*last).max(seq);
    });
}

/// The request on this task queued a config file.
pub(crate) fn note_config() {
    let _ = WRITES.try_with(|w| w.borrow_mut().config = true);
}

impl Hub {
    /// Waits until what `writes` names is on disk; false when a session's log failed.
    pub(crate) async fn wait_written(self: &Arc<Self>, writes: Writes) -> bool {
        let mut saved = true;
        for (id, seq) in writes.logs {
            self.store.expedite(&id);
            let ticket = crate::agent::WriteTicket::new(seq, self.store.progress(&id));
            saved &= ticket.written().await;
        }
        if writes.config {
            let hub = self.clone();
            let _ = cmux_blocking::spawn_blocking(move || hub.config_writer.flush()).await;
        }
        saved
    }
}

#[cfg(test)]
#[path = "request_writes_tests.rs"]
mod tests;
