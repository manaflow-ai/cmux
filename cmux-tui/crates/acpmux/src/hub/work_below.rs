//! Part of `Hub`; see `hub/mod.rs`. Work a session started that runs on past its own turn
//! (manaflow-ai/cmux#25230): a background subagent of its harness (`crate::subagents`), or an
//! open sub-session (`subsessions.rs`) that runs a turn, waits on the person, or has such work
//! of its own. A task is not done while its subagents run, so the session's status dot and lane
//! stay `working` until all of it ends (`views.rs` `status_indicator`, the summary's
//! `subagentsWorkingSince`).
//!
//! Each change is a mux `subagents_working` record (`{since}`, null when it ended), which
//! watchers hear as `_acpmux/session_changed`, and then re-decides the parent's.
//!
//! The unread dot waits for it too (manaflow-ai/cmux#25563): a turn that ends unseen while
//! such work runs leaves the chat read, and the chat turns unread when the last of the work
//! ends, unless a client shows it then or a new turn started. The note is memory only: a
//! daemon restart in between forgets it.

use super::*;

/// The mux record of a change in a session's work below its turn.
pub const RECORD_KIND: &str = "subagents_working";

impl Hub {
    /// A new turn supersedes an earlier turn's deferred unread dot. Serialize with the
    /// background-work transition that could otherwise release it at the same time.
    pub(super) fn clear_deferred_unread(&self, session: &Session) {
        let _mark = session.work_below_since.lock().unwrap_or_else(|e| e.into_inner());
        session.unread_after_work.store(false, Ordering::SeqCst);
    }

    /// A new turn: the earlier turn's foreground subagents are over, whether or not the harness
    /// said so, so the summary's `subagentsRunning` counts none of them again
    /// (`SubagentTree::end_foreground`). A change is recorded as the tap records one.
    pub(super) fn end_foreground_subagents(&self, session: &Session) {
        let count = {
            let mut tree = session.subagents.lock().unwrap_or_else(|e| e.into_inner());
            let before = tree.running_count();
            tree.end_foreground();
            let after = tree.running_count();
            (after != before).then_some(after)
        };
        if let Some(count) = count {
            self.subagents_running(session, count);
        }
    }

    /// Since when work `session` started still runs past its own turn; None while none does.
    pub(super) fn work_below_since(&self, session: &Session) -> Option<u64> {
        let since = *session.work_below_since.lock().unwrap_or_else(|e| e.into_inner());
        (since != 0).then_some(since)
    }

    /// Re-decides whether work `session` started runs past its own turn. When that changed, it
    /// is recorded and the parent's is re-decided. Holds the session's mark while deciding, so
    /// two concurrent decisions never leave an older answer behind; a parent's mark is only
    /// taken after the child's is let go, so the order is always parent before child (sub-session
    /// links form a tree).
    pub(super) fn refresh_work_below(&self, session: &Session) {
        // The same changes move its background waits (`background_waits.rs`).
        self.refresh_background_waits(session);
        {
            let mut mark = session.work_below_since.lock().unwrap_or_else(|e| e.into_inner());
            let works = self.works_below(session);
            if works == (*mark != 0) {
                return;
            }
            *mark = if works { now_ms().max(1) } else { 0 };
            // The turn that ended while the work ran is done now: unread, set before the record
            // so its summary already says so. Every new turn drops the note.
            let unread = !works
                && session.unread_after_work.swap(false, Ordering::SeqCst)
                && !self.attended(session)
                && {
                    let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                    !std::mem::replace(&mut meta.unread, true)
                };
            // Recorded under the mark, so the records keep the order of the changes.
            let since = (*mark != 0).then_some(*mark);
            self.append(session, "mux", RECORD_KIND, json!({"since": since}));
            if unread {
                self.save_meta(session);
                let status = session.status().to_string();
                self.append(session, "mux", "status", json!({"status": status, "read": false}));
            }
        }
        if let Some(parent) = self.subsession_parent(session) {
            self.refresh_work_below(&parent);
        }
    }

    /// A turn of `session` ended while no client showed it: the chat is unread, or, while work
    /// it started still runs, it turns unread when that work ends (`refresh_work_below`). The
    /// mark is held, so the work cannot end between the check and the note.
    /// Each such turn counts for the sidebar now (`unread_turns`), dot or not: several turns that
    /// end while the work runs are several turns.
    pub(super) fn mark_unread_unless_work_below(&self, session: &Session) {
        let mark = session.work_below_since.lock().unwrap_or_else(|e| e.into_inner());
        let works = *mark != 0;
        session.unread_after_work.store(works, Ordering::SeqCst);
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        Self::count_unread_turn(&mut meta);
        if !works {
            meta.unread = true;
        }
    }

    /// Re-decides the work below the turn of `session`'s parent, if it is a sub-session.
    pub(super) fn refresh_parent_work_below(&self, session: &Session) {
        if let Some(parent) = self.subsession_parent(session) {
            self.refresh_work_below(&parent);
        }
    }

    /// The harness is gone and its background subagents with it.
    pub(super) fn end_background_subagents(&self, session: &Session) {
        let ended = {
            let mut tree = session.subagents.lock().unwrap_or_else(|e| e.into_inner());
            tree.end_background();
            tree.take_orphans()
        };
        // Each one it took down can be resumed from its transcript (`subagent_resume.rs`).
        let lost: HashSet<String> = self.subagents_lost(session).into_iter().collect();
        // Every other one that ran ends in the log too, or a client reads it running forever
        // (`subagents::expiry`, `harness_exit`).
        self.end_subagents(session, ended.into_iter().filter(|e| !lost.contains(&e.id)).collect());
        self.refresh_work_below(session);
        // Reports left for its subagents go to it now (`lane_report_subagents.rs`).
        self.subagent_notices_sweep(session);
    }

    /// Before a daemon adopts `session`'s running host (`hosts.rs` `adopt_held`), its subagents
    /// are rebuilt from the log, as the tap followed them live: which subagents the chat started,
    /// so a child's next line is still tagged with its session id, and which still run, so the
    /// summary still counts them. A new daemon started with none, and until each subagent's next
    /// progress event its lines reached clients untagged, as the chat's own (a helper's grep read
    /// as the chat still running grep after its turn ended). A harness start ends the background
    /// subagents of the one before, and a turn start the foreground ones, as live. Read off the
    /// executor (`hosts.rs` `read_whole_log`) by [`Hub::subagents_from_log`], from the adoption
    /// checkpoint of the host's incarnation when there is one (`hosts/checkpoint.rs`); this
    /// applies what it found.
    pub(super) fn seed_subagents(&self, session: &Session, tree: crate::subagents::SubagentTree) {
        let (running_before, running_after) = {
            let mut live = session.subagents.lock().unwrap_or_else(|e| e.into_inner());
            let before = live.running_count();
            live.adopt(tree);
            (before, live.running_count())
        };
        if running_after != running_before {
            self.subagents_running(session, running_after);
        }
        // What the log left running past a harness exit, or quiet past the bound, ends now
        // (`subagents::expiry`).
        let orphans = session.subagents.lock().unwrap_or_else(|e| e.into_inner()).take_orphans();
        self.end_subagents(session, orphans);
        self.sweep_aged_subagents(session, true);
        self.refresh_work_below(session);
    }

    /// Whether a background subagent of `session` runs, or one of its open sub-sessions works.
    fn works_below(&self, session: &Session) -> bool {
        session.subagents.lock().unwrap_or_else(|e| e.into_inner()).background_running() > 0
            || self.subsessions_working(session) > 0
    }

    /// How many open sub-sessions of `session` run a turn, wait on the person, or have work of
    /// their own below theirs (`background_waits.rs` counts each).
    pub(super) fn subsessions_working(&self, session: &Session) -> usize {
        let children: Vec<Arc<Session>> = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            self.subsessions
                .open_children(&session.id)
                .iter()
                .filter_map(|id| sessions.get(id).cloned())
                .collect()
        };
        children
            .iter()
            .filter(|child| {
                matches!(child.status(), SessionStatus::Running | SessionStatus::Waiting)
                    || self.work_below_since(child).is_some()
            })
            .count()
    }

    /// The session that started `session` as its sub-session, if it is one and is here.
    pub(super) fn subsession_parent(&self, session: &Session) -> Option<Arc<Session>> {
        let parent = session.meta.lock().unwrap_or_else(|e| e.into_inner()).subsession.clone()?;
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        sessions.get(&parent.started_by).filter(|p| p.id != session.id).cloned()
    }
}

/// Whether an agent's logged line may start, change or end a subagent (`SubagentTree::annotate`,
/// replayed history included): a native subagent record, or Codex's legacy `spawnAgent` call or
/// `_meta.codex.subagent` activity. Judged from the head, so a scan parses no other line.
pub(super) fn names_subagents(head: &crate::store::RecordHead<'_>) -> bool {
    let kind = head.kind.strip_suffix(".replay").unwrap_or(head.kind);
    matches!(kind, "subagent_spawned" | "subagent_state_update" | "subagent_progress")
        || (matches!(kind, "tool_call" | "tool_call_update")
            && (head.may_contain(b"\"spawnAgent\"") || head.may_contain(b"\"subagent\":{")))
}

#[cfg(test)]
#[path = "work_below_tests.rs"]
mod work_below_tests;
