//! Part of `Hub`; see `hub/mod.rs`. Retention of closed chats' event logs.
//!
//! claude-sr2, 2026-10-26: "acpmux has no log retention. On huge-blue, ~/.acpmux-supervised is 15G
//! across 686 sessions, and a session's events are deleted only with the session. Add a retention
//! policy: closed sessions' event logs are compacted or pruned after N days (default about 14),
//! live and waiting sessions are never touched, the transcript or summary needed to reopen a chat
//! stays, and there's a setting to change it."
//!
//! A pass compacts the log of every chat closed for longer than `store.closedLogDays` (default 14,
//! 0: never) as `store/compact.rs` does: the harness's raw lines and the long strings of tool calls
//! go, every other record stays with its `seq`, and `session.json` is not touched. A chat is left
//! whole while anything may still use its log (`retainable`): it is not closed or not that long, an
//! agent or an agent host runs for it, a client is attached, a turn, queue, watch, move or import
//! is under way, or its log is not read yet after a restart. The compacted log goes in under the
//! chat's append lock, and only when nothing was logged since it was read (`untouched`, and the
//! store's own check of the log's length).
//!
//! The daemon runs a pass on its own once every chat's log is read after its start
//! (`retention_worker`, after `load_logs`), and again when a chat closes, at most every
//! [`SPACING`]: one worker that waits on a wake, no timer. A chat that closes is too recent for
//! that pass; the wake only gives a daemon that runs for weeks a pass now and then, and the chats
//! closed long before it are compacted then. It holds the hub weakly and only its own wake
//! strongly, upgrading for a pass, so it never keeps a hub alive. It ends when the daemon shuts down
//! (its stop condition): the shutdown wakes it (`shutdown_sessions`), it finds the shutdown begun
//! or the hub gone, and returns; a pass under way stops between two chats (`shutting_down`).
//! `_acpmux/retention {dryRun?, archive?, olderThanDays?, only?}` (`acpmux daemon retention`) runs
//! one now: a dry run only measures; `archive` keeps every old segment under
//! `<archive>/<id>/<pass>/`. One pass at a time; it reads each chat's log once, one chat after
//! another, on a blocking thread,
//! and ends with the list (its stop condition), removing any compacted copy it did not put in
//! place. The store's setting is read at the daemon's start.

use super::*;
use crate::store::{CompactMode, Compaction};

/// The least time between two automatic passes.
const SPACING: std::time::Duration = std::time::Duration::from_secs(6 * 60 * 60);

/// What a pass is asked to do.
#[derive(Debug, Default, Clone)]
pub struct RetentionRequest {
    /// Only measure.
    pub dry_run: bool,
    /// Keep every old segment under `<archive>/<id>/<pass>/events/`.
    pub archive: Option<PathBuf>,
    /// Instead of `store.closedLogDays`.
    pub older_than_days: Option<u32>,
    /// One chat only.
    pub only: Option<String>,
}

#[derive(Default)]
struct Report {
    total: Compaction,
    chats: u64,
    skipped: std::collections::BTreeMap<&'static str, u64>,
    largest: Vec<(u64, Value)>,
}

impl Report {
    fn add(&mut self, session: &Session, stats: Compaction) {
        self.chats += 1;
        self.total.bytes_before += stats.bytes_before;
        self.total.bytes_after += stats.bytes_after;
        self.total.dropped += stats.dropped;
        self.total.trimmed += stats.trimmed;
        let freed = stats.bytes_before.saturating_sub(stats.bytes_after);
        let name = session.meta().name;
        self.largest.push((
            freed,
            json!({"sessionId": session.id, "name": name, "bytesBefore": stats.bytes_before, "bytesAfter": stats.bytes_after}),
        ));
        self.largest.sort_by_key(|b| std::cmp::Reverse(b.0));
        self.largest.truncate(10);
    }
}

impl Hub {
    /// A chat closed: a later pass may compact its log. Only wakes the worker; no lock is taken.
    pub(super) fn retention_wake(&self) {
        self.retention_wake.notify_one();
    }

    /// The daemon's one retention worker (module docs): a pass now, then one per wake once
    /// [`SPACING`] passed since the last. Off when `store.closedLogDays` is 0.
    pub fn retention_worker(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let hub = Arc::downgrade(self);
        let wake = self.retention_wake.clone();
        tokio::spawn(async move {
            let mut last: Option<std::time::Instant> = None;
            loop {
                {
                    let Some(hub) = hub.upgrade() else { return };
                    if hub.shutting_down() {
                        return;
                    }
                    let on = hub.config.read().await.store.closed_log_retention().is_some();
                    if on && last.is_none_or(|at| at.elapsed() >= SPACING) {
                        last = Some(std::time::Instant::now());
                        if let Err(e) = hub.retention_pass(RetentionRequest::default()).await {
                            tracing::warn!("log retention: {}", e.message);
                        }
                    }
                }
                wake.notified().await;
            }
        })
    }

    /// Runs one pass (`_acpmux/retention`).
    pub async fn retention_pass(
        self: &Arc<Self>,
        req: RetentionRequest,
    ) -> Result<Value, RpcError> {
        let keep = match req.older_than_days {
            Some(days) => std::time::Duration::from_secs(u64::from(days) * 86_400),
            None => self.config.read().await.store.closed_log_retention().ok_or_else(|| {
                RpcError::invalid_params(
                    "log retention is off (store.closedLogDays is 0); pass olderThanDays",
                )
            })?,
        };
        let only = req.only.as_deref().map(|key| self.resolve(key)).transpose()?;
        if self.retention_running.swap(true, Ordering::SeqCst) {
            return Err(RpcError::new(-32000, "a log retention pass is already running"));
        }
        // Released when the pass ends, or when its task never runs.
        let running = Release(self.retention_running.clone());
        let hub = self.clone();
        tokio::task::spawn_blocking(move || {
            let _running = running;
            hub.retain_logs(keep, &req, only)
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
    }

    fn retain_logs(
        self: &Arc<Self>,
        keep: std::time::Duration,
        req: &RetentionRequest,
        only: Option<Arc<Session>>,
    ) -> Result<Value, RpcError> {
        let started = std::time::Instant::now();
        let cutoff = now_ms().saturating_sub(u64::try_from(keep.as_millis()).unwrap_or(u64::MAX));
        // An unreadable host folder could hide a running agent: no pass then.
        crate::agent_host::load_records(&crate::agent_host::hosts_dir())
            .map_err(|e| RpcError::internal(format!("agent host records: {e:#}")))?;
        let hosted = Self::live_host_sessions();
        let mode = if req.dry_run {
            CompactMode::DryRun
        } else {
            CompactMode::Write { archive: req.archive.as_deref() }
        };
        let mut sessions = only.map_or_else(|| self.sessions(), |s| vec![s]);
        sessions.sort_by_key(|s| s.meta().updated_at);
        let mut report = Report::default();
        for session in sessions {
            // A daemon shutting down ends the pass between two chats.
            if self.shutting_down() {
                *report.skipped.entry("shutdown").or_default() += 1;
                break;
            }
            let seen = match self.retainable(&session, cutoff, &hosted) {
                Ok(seen) => seen,
                Err(why) => {
                    *report.skipped.entry(why).or_default() += 1;
                    continue;
                }
            };
            let staged = match self.store.stage_compaction(&session.id, mode) {
                Ok(Some(staged)) => staged,
                Ok(None) => {
                    *report.skipped.entry("no log").or_default() += 1;
                    continue;
                }
                Err(e) => {
                    tracing::warn!(session = %session.id, "log retention: {e:#}");
                    *report.skipped.entry("error").or_default() += 1;
                    continue;
                }
            };
            let stats = staged.stats;
            if req.dry_run {
                report.add(&session, stats);
                continue;
            }
            // No record lands from here to the rename; anything logged since the read made the
            // log longer, and the store refuses it (`commit_compaction`).
            let committed = {
                let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
                if self.untouched(&session, seen, cutoff) {
                    self.store.commit_compaction(&session.id, staged)
                } else {
                    Ok(false)
                }
            };
            match committed {
                Ok(true) => report.add(&session, stats),
                Ok(false) => *report.skipped.entry("changed").or_default() += 1,
                Err(e) => {
                    tracing::warn!(session = %session.id, "log retention: {e:#}");
                    *report.skipped.entry("error").or_default() += 1;
                }
            }
        }
        let freed = report.total.bytes_before.saturating_sub(report.total.bytes_after);
        tracing::info!(
            dry_run = req.dry_run,
            "log retention: {} closed chats, {} of {} bytes {} in {} ms",
            report.chats,
            freed,
            report.total.bytes_before,
            if req.dry_run { "would be freed" } else { "freed" },
            started.elapsed().as_millis()
        );
        Ok(json!({
            "dryRun": req.dry_run,
            "archive": req.archive,
            "olderThanDays": keep.as_secs() / 86_400,
            "chats": report.chats,
            "bytesBefore": report.total.bytes_before,
            "bytesAfter": report.total.bytes_after,
            "freedBytes": freed,
            "droppedRecords": report.total.dropped,
            "trimmedRecords": report.total.trimmed,
            "skipped": report.skipped,
            "largest": report.largest.into_iter().map(|(_, v)| v).collect::<Vec<_>>(),
        }))
    }

    /// Whether `session`'s log may be compacted now: its `updated_at` then, or the reason it may
    /// not.
    fn retainable(
        &self,
        session: &Session,
        cutoff: u64,
        hosted: &std::collections::HashSet<String>,
    ) -> Result<u64, &'static str> {
        let meta = session.meta();
        if meta.status != SessionStatus::Closed {
            return Err("open");
        }
        if self.age(session, &meta) > cutoff {
            return Err("recent");
        }
        // A chat whose agent is being started holds this lock: it counts as running.
        let no_agent = session.child.try_lock().is_ok_and(|child| child.is_none());
        if !no_agent || hosted.contains(&session.id) {
            return Err("agent");
        }
        if session.attached.load(Ordering::SeqCst) > 0 {
            return Err("attached");
        }
        if !self.session_log_loaded(session) {
            return Err("unread");
        }
        let importing =
            self.importing.lock().unwrap_or_else(|e| e.into_inner()).contains(&session.id);
        if session.purged.load(Ordering::SeqCst)
            || session.replaced.load(Ordering::SeqCst)
            || session.loading.load(Ordering::SeqCst)
            || session.turn().is_some()
            || session.queued() > 0
            || meta.watching.is_some()
            || session.moving().is_some()
            || importing
        {
            return Err("busy");
        }
        if self.store.compacted_seq(&session.id) == Some(session.seq.load(Ordering::SeqCst)) {
            return Err("compacted");
        }
        Ok(meta.updated_at)
    }

    /// When the chat last changed: its log's last write, or its `updatedAt` if earlier. A chat
    /// whose `session.json` was saved again (a stop that changed nothing, before #25863; a draft)
    /// is as old as its last record; with no log on disk, as old as its `updatedAt` says.
    fn age(&self, session: &Session, meta: &SessionMeta) -> u64 {
        let written = self.store.log_written_at(&session.id).unwrap_or(meta.updated_at);
        written.min(meta.updated_at)
    }

    /// Under the chat's append lock, right before the compacted log goes in: still closed, with
    /// no agent, client, move or import, and no import replacing it (`transfer_in.rs` marks the
    /// chat it replaces, then waits for this lock before it moves the chat's folder aside). A
    /// reopen sets its status before it logs it, and so do a start, a purge and a move their
    /// flags: one that came first is seen here, one that comes later logs its first record after
    /// the compacted log is in place, as for a chat compacted any time before. Only locks that
    /// are never held across an append are taken (`meta`, as `append_at` does under this one;
    /// `child` is only tried).
    ///
    /// `seen` is the chat's `updated_at` when `retainable` let it in. Every status write sets it
    /// under the meta lock before it logs the status (`write_status`), so a reopen and a close
    /// since, whose records still wait for this lock, leave it changed: the chat is left whole.
    /// A status write that set its status but has not logged it yet is still under way
    /// (`status_writes`), and one logged since the pass looked makes the log new again (`age`).
    fn untouched(&self, session: &Session, seen: u64, cutoff: u64) -> bool {
        let meta = session.meta();
        meta.status == SessionStatus::Closed
            && meta.updated_at == seen
            && session.status_writes.load(Ordering::SeqCst) == 0
            && self.age(session, &meta) <= cutoff
            && session.child.try_lock().is_ok_and(|child| child.is_none())
            && session.attached.load(Ordering::SeqCst) == 0
            && !session.purged.load(Ordering::SeqCst)
            && !session.replaced.load(Ordering::SeqCst)
            && !session.loading.load(Ordering::SeqCst)
            && session.moving().is_none()
            && !self.importing.lock().unwrap_or_else(|e| e.into_inner()).contains(&session.id)
    }
}

/// Ends the pass's hold on `Hub::retention_running` however it ends.
struct Release(Arc<AtomicBool>);

impl Drop for Release {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

#[cfg(test)]
#[path = "retention_tests.rs"]
mod tests;
