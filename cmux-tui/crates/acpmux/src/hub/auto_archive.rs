//! Part of `Hub`; see `hub/mod.rs`. A finished chat archives itself, so the chat lists and the
//! sidebar keep only the work still going.
//!
//! Leo, 2026-11-03 (ask-6ef2624788, the Chief's brainstorm item "auto-close finished lanes and
//! workspaces so the sidebar stays small"): "go do all those/help out where you can".
//!
//! A chat is finished when it is ready or hibernated (`Idle`) and nothing in it is at work: no
//! turn running, queued or waiting on a permission or question, no background task, background
//! subagent or sub-session at work (`Hub::session_at_work`), and no background process of its
//! harness. It archives once it was not used for `autoArchiveHours` (unset or 0, the default: off;
//! a chat's own `autoArchive` tag of a number of hours turns it on for that chat): used
//! means its last turn ended, it was opened on screen or typed into (`wake_for`), or it was sent
//! a prompt; this daemon's start counts as a use, so a restart or an upgrade archives nothing at
//! once. It archives as the chat menu's Archive does (the `archived` tag, valued with when), plus
//! `autoArchived`: nothing is closed or deleted, its agent session and log stay.
//!
//! - A chat another chat started (its lineage parent, a sub-session's starter, `spawnedBy`)
//!   archives only while that chat is finished too, and a chat archives only after every chat it
//!   started that is still listed: a tree leaves the lists from its leaves up, and no child ever
//!   surfaces as its own row because its parent left first (`views.rs` `listed_parent`).
//! - A chat nobody started (a person's own) stays while its last reply is unread.
//! - Never: a closed, disconnected or moved chat, one archived by hand, or one tagged
//!   `autoArchive` `off` (or `never`, `0`); a tag of a number of hours is that chat's own wait.
//! - An auto-archived chat comes back on its own: a prompt, opening it on screen or typing into
//!   it removes both tags (`auto_archive_used`). One archived by hand stays archived.
//!
//! One worker per daemon, started once every chat's log is read (`daemon.rs`, beside the log
//! retention worker): it sleeps until the earliest chat is due, or [`RECHECK`] at most, and
//! wakes early when a turn ends or the settings reload; passes are at least [`SPACING`] apart.
//! It holds the hub weakly and ends when the daemon shuts down (its stop condition): the
//! shutdown wakes it, it finds the shutdown begun or the hub gone, and returns. A pass reads each
//! chat's background-task records, so it runs on a blocking thread.

use super::*;

/// Set with `archived` when this worker archived the chat (Unix ms).
pub(crate) const AUTO_ARCHIVED_TAG: &str = "autoArchived";
/// A chat's own rule: `off` (`never`, `0`) or a number of hours.
pub(crate) const AUTO_ARCHIVE_TAG: &str = "autoArchive";
const ARCHIVED_TAG: &str = "archived";

/// The least time between two passes.
const SPACING: std::time::Duration = std::time::Duration::from_secs(60);
/// The longest the worker sleeps: what blocked a chat (a background task, a parent's work) may
/// end without a wake.
const RECHECK: std::time::Duration = std::time::Duration::from_secs(30 * 60);

/// The worker's state on the hub.
pub(crate) struct AutoArchive {
    /// A turn ended, the settings reloaded, or the daemon shuts down.
    pub(super) wake: Arc<Notify>,
    /// When each chat was last opened, typed into or prompted in this daemon run (Unix ms).
    used: StdMutex<std::collections::HashMap<String, u64>>,
    /// This daemon's start (Unix ms): the first use of every chat.
    since: u64,
}

impl Default for AutoArchive {
    fn default() -> Self {
        Self { wake: Arc::new(Notify::new()), used: Default::default(), since: now_ms() }
    }
}

/// What one pass did.
#[derive(Debug, Default, PartialEq)]
pub(crate) struct Pass {
    /// The chats it archived.
    pub archived: Vec<String>,
    /// When the next chat is due (Unix ms), if one is waiting only for time.
    pub next_due: Option<u64>,
}

/// A chat's own rule from its `autoArchive` tag: Some(None) never, Some(Some(ms)) its own wait.
fn own_rule(value: &str) -> Option<Option<u64>> {
    match value.trim() {
        "off" | "never" | "false" => Some(None),
        hours => match hours.parse::<u64>() {
            Ok(0) => Some(None),
            Ok(h) => Some(Some(h.saturating_mul(3_600_000))),
            Err(_) => None,
        },
    }
}

/// What a pass reads of one chat, under its meta lock once.
struct Facts {
    parent: Option<String>,
    listed: bool,
    unread: bool,
    moved: bool,
    /// None: never archives on its own.
    after: Option<u64>,
    last_use: u64,
}

impl Hub {
    /// A person or an agent used `session`: an auto-archived chat comes back, and its wait starts
    /// again. One archived by hand stays archived.
    pub(super) fn auto_archive_used(&self, session: &Session) {
        self.auto_archive
            .used
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(session.id.clone(), now_ms());
        if session.read_meta(|m| m.tags.contains_key(AUTO_ARCHIVED_TAG)) {
            let remove = [ARCHIVED_TAG.to_owned(), AUTO_ARCHIVED_TAG.to_owned()];
            self.set_tags(session, None, &remove, None);
            tracing::info!(session = %session.id, "auto-archive: used again, unarchived");
        }
    }

    /// A turn ended or the settings changed: the worker looks again.
    pub(super) fn auto_archive_wake(&self) {
        self.auto_archive.wake.notify_one();
    }

    /// The daemon's one auto-archive worker (module docs).
    pub fn auto_archive_worker(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let hub = Arc::downgrade(self);
        let wake = self.auto_archive.wake.clone();
        tokio::spawn(async move {
            loop {
                let started = std::time::Instant::now();
                let next_due = {
                    let Some(hub) = hub.upgrade() else { return };
                    if hub.shutting_down() {
                        return;
                    }
                    // Off, a pass still archives the chats whose own tag turns it on.
                    let after = hub.config.read().await.auto_archive_after();
                    let after = after.map(|a| u64::try_from(a.as_millis()).unwrap_or(u64::MAX));
                    let pass =
                        tokio::task::spawn_blocking(move || hub.auto_archive_pass(after, now_ms()));
                    pass.await.ok().and_then(|p| p.next_due)
                };
                let wait = next_due
                    .map(|at| std::time::Duration::from_millis(at.saturating_sub(now_ms())))
                    .unwrap_or(RECHECK)
                    .clamp(SPACING, RECHECK);
                tokio::select! {
                    _ = tokio::time::sleep(wait) => {}
                    _ = wake.notified() => {
                        // A wake never runs passes closer than SPACING.
                        let rest = SPACING.saturating_sub(started.elapsed());
                        tokio::time::sleep(rest).await;
                    }
                }
            }
        })
    }

    fn auto_archive_facts(&self, session: &Session, after: Option<u64>, at: u64) -> Facts {
        let used = self.auto_archive.used.lock().unwrap_or_else(|e| e.into_inner()).get(&session.id).copied();
        session.read_meta(|m| {
            let tag = |key: &str| {
                m.tags
                    .get(key)
                    .filter(|t| t.expires_at.is_none_or(|e| e > at))
                    .map(|t| t.value.as_str())
            };
            let ended = m.last_turn.as_ref().and_then(|t| t.get("endedAt")).and_then(Value::as_u64);
            Facts {
                parent: super::views::activity_parent(m).filter(|p| *p != m.id).map(str::to_owned),
                listed: tag(ARCHIVED_TAG).is_none(),
                unread: m.unread,
                moved: m.moved_to.is_some(),
                after: match tag(AUTO_ARCHIVE_TAG).and_then(own_rule) {
                    Some(own) => own,
                    None => after,
                },
                last_use: [self.auto_archive.since, m.created_at, ended.unwrap_or(0), used.unwrap_or(0)]
                    .into_iter()
                    .max()
                    .unwrap_or(0),
            }
        })
    }

    /// Ready or hibernated with nothing at work in it (module docs).
    fn auto_archive_finished(&self, session: &Session) -> bool {
        matches!(session.status(), SessionStatus::Ready | SessionStatus::Idle)
            && !self.session_at_work(session)
            && !self.any_process_running(session)
    }

    /// One pass at `now` with the default wait `after` (both ms; None: only chats with their own): archives every chat due, leaves
    /// first, and says when the next one is due.
    pub(crate) fn auto_archive_pass(&self, after: Option<u64>, now: u64) -> Pass {
        let mut pass = Pass::default();
        if self.shutting_down() {
            return pass;
        }
        let sessions: std::collections::HashMap<String, Arc<Session>> =
            self.sessions().into_iter().map(|s| (s.id.clone(), s)).collect();
        let mut facts: std::collections::HashMap<&str, Facts> =
            sessions.iter().map(|(id, s)| (id.as_str(), self.auto_archive_facts(s, after, now))).collect();
        // Read once each, and only for a chat that got that far.
        let mut finished: std::collections::HashMap<String, bool> = Default::default();
        let mut is_finished = |id: &str| -> bool {
            *finished
                .entry(id.to_owned())
                .or_insert_with(|| sessions.get(id).is_some_and(|s| self.auto_archive_finished(s)))
        };
        // Leaves first: each round archives the chats with no listed child left, until a round
        // archives none (a tree's depth bounds it).
        loop {
            let mut with_children: std::collections::HashSet<&str> = Default::default();
            for f in facts.values().filter(|f| f.listed) {
                if let Some(parent) = f.parent.as_deref()
                    && let Some((key, _)) = sessions.get_key_value(parent)
                {
                    with_children.insert(key.as_str());
                }
            }
            let mut due = Vec::new();
            for (id, f) in &facts {
                let Some(wait) = f.after else { continue };
                if !f.listed || f.moved || with_children.contains(id) {
                    continue;
                }
                // A person's own chat stays while its last reply is unread.
                if f.parent.is_none() && f.unread {
                    continue;
                }
                let at = f.last_use.saturating_add(wait);
                if at > now {
                    pass.next_due = Some(pass.next_due.map_or(at, |n| n.min(at)));
                    continue;
                }
                due.push(*id);
            }
            let mut archived_any = false;
            for id in due {
                let parent = facts[id].parent.clone();
                if let Some(parent) = parent.as_deref()
                    && sessions.contains_key(parent)
                    && !is_finished(parent)
                {
                    continue;
                }
                if !is_finished(id) || self.shutting_down() {
                    continue;
                }
                let session = &sessions[id];
                let stamp = Value::String(now_ms().to_string());
                let mut set = serde_json::Map::new();
                set.insert(ARCHIVED_TAG.into(), stamp.clone());
                set.insert(AUTO_ARCHIVED_TAG.into(), stamp);
                if let Err(e) = self.set_tags_answered(session, Some(&set), &[], None) {
                    tracing::warn!(session = %id, "auto-archive: {}", e.message);
                    continue;
                }
                // Used while this pass looked: it comes back at once.
                let used = self.auto_archive.used.lock().unwrap_or_else(|e| e.into_inner()).get(*id).copied();
                if used.is_some_and(|u| u > now) || !self.auto_archive_finished(session) {
                    let remove = [ARCHIVED_TAG.to_owned(), AUTO_ARCHIVED_TAG.to_owned()];
                    self.set_tags(session, None, &remove, None);
                    continue;
                }
                tracing::info!(session = %id, "auto-archive: finished and unused, archived");
                if let Some(f) = facts.get_mut(id) {
                    f.listed = false;
                }
                pass.archived.push(id.to_string());
                archived_any = true;
            }
            if !archived_any {
                break;
            }
        }
        pass
    }
}

#[cfg(test)]
#[path = "auto_archive_tests.rs"]
mod tests;
