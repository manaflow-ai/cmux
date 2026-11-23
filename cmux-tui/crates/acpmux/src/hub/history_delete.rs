//! Part of `Hub`; see `hub/mod.rs`. Deleting old chat history on a setting.
//!
//! The customization matrix row history-retention ("How long chat history is kept, or turn it
//! off"): Claude Code's `cleanupPeriodDays` and Codex's `history.persistence` say how long chat history is
//! kept. cmux compresses old chats (`cold_archive.rs`) and compacts closed chats' logs
//! (`retention.rs`) but kept every chat forever.
//!
//! With `agents.chats.deleteHistoryAfterDays` set to a number of days (0, the default, is never:
//! nothing is deleted), the retention worker (`hub/retention.rs`, same wakes, spacing and stop
//! condition) deletes every chat that is closed, or cold-archived and idle, and has had no record
//! logged and no change for that long: the same delete as `acpmux session rm` (`Hub::kill` with
//! `purge`), its folder, log, cold archive, uploads and ledger entry gone. A delete cannot be
//! undone. A chat is never deleted while anything may use it ([`Hub::history_deletable`]): it is
//! open (running, waiting, or idle and not archived), pinned, an agent or agent host runs for it,
//! a client is attached, a turn, queue, permission, background command or subagent, watch, move,
//! import or load is under way, or its log is not read yet after a restart. The check runs twice:
//! once for the scan, then again under the leases a turn, an agent start and a mode change take
//! (`stop_if_idle.rs`), held through the delete, with the chat's revision unchanged since the
//! scan. The setting is read from the settings file at each pass.

use super::*;

/// After how many days with no activity a closed chat's history is deleted; 0 (the default) is
/// never.
pub(crate) const SETTING: &str = "agents.chats.deleteHistoryAfterDays";
/// The tag that keeps a chat whatever its age.
const KEPT_TAG: &str = "pinned";

/// How long a chat stays unchanged before a pass deletes it, from the settings document; None
/// when the setting is absent, 0, or not a positive number of days (`7`, `"7"`, `"7d"`).
pub(crate) fn delete_after(doc: &Value) -> Option<std::time::Duration> {
    let days = match crate::user_settings::value(doc, SETTING)? {
        Value::Number(n) => n.as_u64()?,
        Value::String(s) => {
            let s = s.trim();
            s.strip_suffix('d').unwrap_or(s).parse::<u64>().ok()?
        }
        _ => return None,
    };
    (days > 0).then(|| std::time::Duration::from_secs(days.saturating_mul(86_400)))
}

/// [`delete_after`] of the settings file as it is now.
fn delete_after_now() -> Option<std::time::Duration> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => delete_after(&doc),
        _ => None,
    }
}

impl Hub {
    /// Whether a pass may delete `session`, unchanged since before `cutoff` (Unix ms): its
    /// revision (`lastSeq`), or why not (module docs).
    pub(super) fn history_deletable(
        &self,
        session: &Session,
        cutoff: u64,
        hosted: &std::collections::HashSet<String>,
    ) -> Result<u64, &'static str> {
        let meta = session.meta();
        let cold = meta.cold.is_some() || self.store.is_cold(&session.id);
        match meta.status {
            SessionStatus::Closed => {}
            SessionStatus::Idle if cold => {}
            _ => return Err("open"),
        }
        if meta.tags.get(KEPT_TAG).is_some_and(|tag| tag.expires_at.is_none_or(|at| at > now_ms()))
        {
            return Err("kept");
        }
        if self.age(session, &meta) > cutoff {
            return Err("recent");
        }
        let no_agent = session.child.try_lock().is_ok_and(|child| child.is_none());
        if !no_agent || hosted.contains(&session.id) {
            return Err("agent");
        }
        if session.attached.load(Ordering::SeqCst) > 0 {
            return Err("attached");
        }
        // A cold chat's log is not read at a start; one with its log on disk must be.
        if !cold && !self.session_log_loaded(session) {
            return Err("unread");
        }
        let importing =
            self.importing.lock().unwrap_or_else(|e| e.into_inner()).contains(&session.id);
        if self.archive_held(session)
            || session.status_writes.load(Ordering::SeqCst) > 0
            || session.purging.load(Ordering::SeqCst)
            || meta.watching.is_some()
            || importing
            || self.has_auto_resume_mark(session)
        {
            return Err("busy");
        }
        Ok(meta.last_seq)
    }

    /// Deletes `session` when it is still deletable under the leases every turn, agent start and
    /// mode change take, and its revision is still `seen`. Whether it was deleted.
    async fn delete_old_chat(
        &self,
        session: &Arc<Session>,
        cutoff: u64,
        hosted: &std::collections::HashSet<String>,
        seen: u64,
    ) -> Result<bool, RpcError> {
        let Ok(_turn) = session.turn_lock.try_lock() else { return Ok(false) };
        let Ok(using) = session.harness_use.try_write() else { return Ok(false) };
        let Ok(spawning) = session.spawn_lock.try_lock() else { return Ok(false) };
        if self.history_deletable(session, cutoff, hosted) != Ok(seen) {
            return Ok(false);
        }
        drop(spawning);
        self.kill_held(session, true, using.downgrade()).await?;
        Ok(true)
    }

    /// The automatic pass, on the retention worker (`hub/retention.rs`): nothing when the
    /// setting is 0 or absent.
    pub(super) async fn history_delete_pass(self: &Arc<Self>) {
        let Ok(after) = tokio::task::spawn_blocking(delete_after_now).await else { return };
        if let Some(after) = after {
            self.history_delete_pass_after(after).await;
        }
    }

    /// [`Self::history_delete_pass`] for chats unchanged for longer than `after`: how many it
    /// deleted. Oldest first, one at a time, stopping between two chats at a shutdown.
    pub(super) async fn history_delete_pass_after(
        self: &Arc<Self>,
        after: std::time::Duration,
    ) -> u64 {
        let cutoff = now_ms().saturating_sub(u64::try_from(after.as_millis()).unwrap_or(u64::MAX));
        // An unreadable host folder could hide a running agent: no pass then.
        if let Err(e) = crate::agent_host::load_records(&crate::agent_host::hosts_dir()) {
            tracing::warn!("history delete: agent host records: {e:#}");
            return 0;
        }
        let hosted = Self::live_host_sessions();
        let mut sessions = self.session_handles();
        sessions.sort_by_key(|s| s.meta().updated_at);
        let mut deleted = 0u64;
        for session in sessions {
            if self.shutting_down() {
                break;
            }
            let Ok(seen) = self.history_deletable(&session, cutoff, &hosted) else { continue };
            match self.delete_old_chat(&session, cutoff, &hosted, seen).await {
                Ok(true) => deleted += 1,
                Ok(false) => {}
                Err(e) => tracing::warn!(session = %session.id, "history delete: {}", e.message),
            }
        }
        if deleted > 0 {
            tracing::info!("history delete: {deleted} chats unchanged for {after:?}");
        }
        deleted
    }
}

#[cfg(test)]
#[path = "history_delete_tests.rs"]
mod tests;
