//! Part of `Hub`; see `hub/mod.rs`. The daemon's own background tasks (`bg_tasks.rs`) in the
//! process registry (`processes.rs`), so every client lists them as it lists a harness's shells:
//! the tray above the composer, Session Info's Background tasks, the phone, `acpmux process ls`.
//!
//! Why: acpmux's Bash hook rewrites a Claude Code background shell into a daemon task
//! (`bg_hook.rs`), so Claude Code reports no background shell, and the registry was the only
//! list a client reads. A chat said "Review is running in the background" while every surface
//! showed nothing running (2026-11-26, a Codex review that ran 6 minutes).
//!
//! The task's folder is the truth; a row is its view at a moment, logged as a `process_update`
//! only when it changed ([`ProcessTable::daemon_upsert`]):
//! - a start logs the running row (`bg_start_as`);
//! - every task is watched (`bg_notify.rs` `bg_watch`, one thread for all), and its end, however
//!   it came (exit, stop, a signal, a runner that died: `lost`), logs the ended row;
//! - a daemon start watches every task still running and logs its row (`bg_notify_resume`);
//! - each listing first checks every row it holds as running against the folder
//!   ([`Hub::bg_reconcile`]), so an end while no daemon ran, or one a watch missed, never stays
//!   `running`.
//!
//! A workflow's machine task (a stable id with its claim, `bg_start_with_id`) shows in its
//! workflow's card and panel, never as a row.

use super::processes::{Process, ProcessTable, daemon_process};
use super::*;
use crate::bg_run::{self, Record};
use std::path::Path;

/// One publish at a time per chat: a row's change, its `process_update` append and the change put
/// in the table go together, so a start, a watch, a listing and a kill that publish one task at
/// once log its states in the order they were decided (a later `running` after its `exited`
/// showed it running again). Per chat, so one chat's slow log write never holds another's. An
/// entry lives while a publish holds it, and the map drops the ones none holds.
// test-hook-allow: holds no hook; it only orders a chat's publishes, keyed by the chat's id
static PUBLISH: std::sync::LazyLock<StdMutex<HashMap<String, std::sync::Weak<StdMutex<()>>>>> =
    std::sync::LazyLock::new(Default::default);

/// Chat `session_id`'s publish lock ([`PUBLISH`]).
fn publish_lock(session_id: &str) -> Arc<StdMutex<()>> {
    let mut locks = PUBLISH.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(lock) = locks.get(session_id).and_then(std::sync::Weak::upgrade) {
        return lock;
    }
    locks.retain(|_, held| held.strong_count() > 0);
    let lock = Arc::new(StdMutex::new(()));
    locks.insert(session_id.to_owned(), Arc::downgrade(&lock));
    lock
}

impl Hub {
    /// Logs task `record`'s row of chat `session` as its folder says now, when it changed.
    pub(super) fn bg_publish(&self, session: &Session, dir: &Path, record: &Record) {
        if session.purged.load(Ordering::SeqCst) || is_workflow_task(dir, &record.id) {
            return;
        }
        let folder = self.bg_records(dir);
        let view = fresh_view(dir, record, folder.segments(&record.id));
        self.bg_publish_view(session, &view);
    }

    fn bg_publish_view(&self, session: &Session, view: &Value) {
        let Some(process) = daemon_process(session, view) else { return };
        self.bg_log(session, |table| table.daemon_change(process));
    }

    /// Logs the daemon row change `change` decides from chat `session`'s table, and puts it in the
    /// table only once the log took it: a record the log refused (its backlog full, a failed write)
    /// reaches no client, so the table must not say it either, or the next look would find nothing
    /// to change and the row would stay as no client heard it. The table is read in before the
    /// chat's publish lock, so a first read of a long log never holds a publish.
    fn bg_log(&self, session: &Session, change: impl FnOnce(&ProcessTable) -> Option<Process>) {
        drop(self.process_table(session));
        let lock = publish_lock(&session.id);
        let _one = lock.lock().unwrap_or_else(|e| e.into_inner());
        let Some(process) = change(&self.process_table(session)) else { return };
        let msg = json!({"process": process});
        let (_, stored) = self.append_logged(session, "mux", "process_update", msg, None);
        if stored {
            self.process_table(session).daemon_apply(process);
        }
    }

    /// Task `id` of folder `dir` ended (its watch fired): its row says how.
    pub(super) fn bg_ended(&self, dir: &Path, session_id: &str, id: &str) {
        if self.stopping.load(Ordering::SeqCst) {
            return;
        }
        let Some(session) = self.session_get(session_id) else { return };
        let Some(record) = bg_run::read_record(dir, id) else { return };
        // A runner that outlived a purge writes into no later chat of this id.
        let generation = super::bg_tasks::bg_generation(dir, false).ok();
        if generation.as_deref() == Some(record.generation.as_str()) {
            self.bg_publish(&session, dir, &record);
        }
    }

    /// Chat `session`'s rows checked against its folder before a listing answers:
    /// - a task that runs with no row (a start whose row a history reload undid before its log
    ///   took it, a launch whose record read failed, a task from before this daemon's rows) gets
    ///   one;
    /// - a row that says a task runs: one that ended (while no daemon ran, or unseen) is logged
    ///   ended, and one whose record is surely gone (a purge, another generation) is `lost`.
    ///
    /// Cheap at rest: one look at the folder's cache, a lock probe per task with no end written,
    /// and a record read per live row.
    pub(super) fn bg_reconcile(&self, session: &Session) {
        let dir = self.bg_dir(session);
        let running = self.bg_running_tasks(session);
        if !running.is_empty() {
            let missing: Vec<String> = {
                let table = self.process_table(session);
                running
                    .into_iter()
                    .map(|(id, _)| id)
                    .filter(|id| table.daemon_row_missing(&format!("{}/{id}", session.id)))
                    .collect()
            };
            for id in missing {
                if let Some(record) = bg_run::read_record(&dir, &id) {
                    self.bg_publish(session, &dir, &record);
                }
            }
        }
        let live = self.process_table(session).daemon_live();
        if live.is_empty() {
            return;
        }
        let folder = self.bg_records(&dir);
        for (row, task) in live {
            // The record itself, not the folder's look: a look that failed to list (too many open
            // files) holds no task, and that is no proof the task is gone.
            if let Ok((dir, record)) = self.bg_record(session, &task) {
                let view = fresh_view(&dir, &record, folder.segments(&task));
                self.bg_publish_view(session, &view);
            } else if surely_gone(&dir, &task) {
                self.bg_log(session, |table| table.daemon_lost(&row, now_ms()));
            }
            // Else unreadable now (a read that failed): the next listing looks again.
        }
    }

    /// A wait of chat `session` moved here (`server/bg_rearm.rs`) runs again as a new task: the
    /// row of the task it was, `from`, ends and gives its call to the new one.
    pub(crate) fn bg_moved(&self, session: &Session, from: &str) {
        let row = format!("{}/{from}", session.id);
        self.bg_log(session, |table| table.daemon_moved_change(&row));
    }

    /// `_acpmux/process/kill` of a daemon task: its runner stops it, as the person's stop does
    /// (`bg_stop`), and its row says so. One its folder no longer holds is `lost`. A task still
    /// running after the stop (its stop could not be sent, or its runner outlived the wait) is a
    /// refusal, never a quiet success.
    pub(super) async fn bg_kill(
        &self,
        session: &Arc<Session>,
        task: &str,
    ) -> Result<Value, RpcError> {
        match self.bg_stop(session, task).await {
            Ok(view) => {
                self.bg_publish_view(session, &view);
                if view.get("state").and_then(Value::as_str) == Some("running") {
                    return Err(RpcError::internal(format!(
                        "background task {task} did not stop; it still runs"
                    )));
                }
            }
            Err(e) if e.code == RpcError::not_found("").code => self.bg_reconcile(session),
            Err(e) => return Err(e),
        }
        Ok(json!({}))
    }

    /// `_acpmux/process/tail` of a daemon task: its spool (`bg_output`), in the tail's shape.
    pub(super) fn bg_tail(
        &self,
        session: &Arc<Session>,
        task: &str,
        from: Option<u64>,
        max: Option<u64>,
    ) -> Result<Value, RpcError> {
        let view = self.bg_output(session, task, from, max)?;
        let byte = |k: &str| view.get(k).and_then(Value::as_u64).unwrap_or(0);
        let next = byte("nextByte");
        let running = view.get("state").and_then(Value::as_str) == Some("running");
        Ok(json!({
            "data": view.get("data").cloned().unwrap_or_else(|| json!("")),
            "fromByte": byte("fromByte"),
            "nextByte": next,
            "eof": !running && next >= byte("totalBytes"),
        }))
    }
}

/// Task `record`'s view (`bg_tasks::bg_view_at`, no output) from its record as it is now. A view
/// that reads `lost` (no end written, the runner's lock free) reads the record once more: the
/// runner writes its end and then lets go of its lock, so a task that ended between the read and
/// the look is not a runner that died.
fn fresh_view(dir: &Path, record: &Record, segments: Option<&[u64]>) -> Value {
    let fresh = bg_run::read_record(dir, &record.id);
    let record = fresh.as_ref().unwrap_or(record);
    let view = super::bg_tasks::bg_view_at(dir, record, 0, segments);
    if view.get("state").and_then(Value::as_str) != Some("lost") {
        return view;
    }
    match bg_run::read_record(dir, &record.id) {
        Some(again) if again.ended_at.is_some() => {
            super::bg_tasks::bg_view_at(dir, &again, 0, segments)
        }
        _ => view,
    }
}

/// Whether task `id` is surely no longer the folder's: its record is gone (a purge moved the folder
/// away), or it is of another generation than the folder's. A read that fails proves nothing.
fn surely_gone(dir: &Path, id: &str) -> bool {
    let path = dir.join(format!("{id}.json"));
    match std::fs::symlink_metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return true,
        Err(_) => return false,
        Ok(_) => {}
    }
    let generation = super::bg_tasks::bg_generation(dir, false).ok();
    let record = bg_run::read_record(dir, id);
    matches!((generation, record), (Some(g), Some(r)) if r.generation != g)
}

/// A workflow's machine task: started with a stable id, which leaves its claim beside it
/// (`bg_tasks.rs` `bg_start_as`).
fn is_workflow_task(dir: &Path, id: &str) -> bool {
    dir.join(format!("{id}.claim")).exists()
}

#[cfg(all(test, unix))]
#[path = "bg_registry_tests.rs"]
mod tests;
