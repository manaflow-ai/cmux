//! Part of `Hub`; see `hub/mod.rs`. Archived chats, and the automatic archive of inactive ones.
//!
//! Leo, 2026-11-18: "there's the archived/settled chats for it, etc", of the Claude app's Code
//! tab, whose setting reads "Archive inactive sessions: Automatically archive local sessions
//! after a period of no activity. Sessions that are running or have background work are never
//! archived".
//!
//! A chat is archived while it carries the tag `archived` (not past an expiry), valued with when
//! (Unix ms): the lists leave it out (webviews `sessionList.ts`, the app's `AgentChatDetail`),
//! `acpmux ls --archived` lists it. `_acpmux/archive` and `acpmux archive` / `acpmux unarchive`
//! set or remove it through [`Hub::set_archived`]. One the daemon archived on its own also
//! carries `archivedBy=auto`, so a list can say so; any other change of `archived` (an unarchive,
//! an archive by hand, a `_acpmux/tag` write) drops that marker (`tags.rs`).
//!
//! With `agents.chats.archiveInactive` set to a number of days (`never`, the default, is off), a
//! pass [`FIRST_PASS_AFTER`] after the daemon read its chats, then every [`PASS_EVERY`], archives
//! each chat with no activity for that long: its `updatedAt`,
//! which every logged record moves (a prompt, a reply, a status, a tag change). So an unarchive,
//! which logs its tag change, starts a new period: the chat is not archived again until it has
//! been inactive that long since. A chat is never archived while it works or waits on someone
//! (its turn, queue, a pending permission or question, a background command or subagent, a
//! continuation, work below it, a move or a load), nor when it is pinned or a side chat
//! ([`Hub::inactive_archivable`]). A pass reads the setting from the settings file each time,
//! visits every chat once without sorting (O(chats), metadata only, no log read), archives at
//! most [`PASS_MAX`] (the rest go on the next pass), and stops between two chats at a shutdown.
//!
//! The worker holds the hub weakly and runs in the hub's scope, so it ends with the daemon (its
//! stop condition): the scope's cancel at shutdown, a shutdown begun, or the hub gone.

use super::*;

/// The tag an archived chat carries, valued with when (webviews `sessionList.ts` `ARCHIVED_TAG`).
pub(crate) use super::plan_build::ARCHIVED_TAG;
/// Who archived it, when not the person: `auto` for this pass.
pub(crate) const ARCHIVED_BY_TAG: &str = "archivedBy";
/// [`ARCHIVED_BY_TAG`]'s value for a chat this pass archived.
pub(crate) const ARCHIVED_BY_AUTO: &str = "auto";
/// After how many days of no activity a chat is archived on its own; `never` (the default) is off.
pub(crate) const SETTING: &str = "agents.chats.archiveInactive";
/// How often a pass runs: the threshold is days, so a chat is archived at most this late.
const PASS_EVERY: std::time::Duration = std::time::Duration::from_secs(10 * 60);
/// The first pass: soon after a start, so a daemon restarted often still passes, but never in the
/// start's own busy seconds.
const FIRST_PASS_AFTER: std::time::Duration = std::time::Duration::from_secs(60);
/// The most chats one pass archives: the first pass after the setting is turned on may find
/// thousands; each is a metadata save.
const PASS_MAX: usize = 200;
/// The tags that keep a chat out of the automatic archive: pinned, and side chats (and an aside's
/// throwaway copy), which no list shows anyway.
const KEPT_TAGS: [&str; 3] = ["pinned", "side", "aside"];

/// How long a chat stays inactive before a pass archives it, from the settings document; None
/// when the setting is `never`, absent or not a positive number of days (`7`, `"7"`, `"7d"`).
pub(crate) fn archive_after(doc: &Value) -> Option<std::time::Duration> {
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

/// [`archive_after`] of the settings file as it is now.
fn archive_after_now() -> Option<std::time::Duration> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => archive_after(&doc),
        _ => None,
    }
}

/// Whether `meta` carries tag `key`, not past its expiry at `now`.
fn has_tag(meta: &SessionMeta, key: &str, now: u64) -> bool {
    meta.tags.get(key).is_some_and(|tag| tag.expires_at.is_none_or(|at| at > now))
}

impl Hub {
    /// Archive `session` (`archived`) or bring it back; `auto` marks an archive the daemon made
    /// on its own ([`ARCHIVED_BY_TAG`]). Whether anything changed: an unarchive of a chat that is
    /// not archived, or an archive of one archived the same way, logs nothing. An archive in force
    /// keeps its time when only who archived it changes.
    pub(crate) fn set_archived(
        &self,
        session: &Session,
        archived: bool,
        auto: bool,
    ) -> Result<bool, RpcError> {
        let now = now_ms();
        let (since, marked) = session.read_meta(|m| {
            let since = has_tag(m, ARCHIVED_TAG, now)
                .then(|| m.tags.get(ARCHIVED_TAG).map(|t| t.value.clone()))
                .flatten();
            (since, m.tags.contains_key(ARCHIVED_BY_TAG))
        });
        if !archived {
            if since.is_none() && !marked {
                return Ok(false);
            }
            let remove = [ARCHIVED_TAG.to_owned(), ARCHIVED_BY_TAG.to_owned()];
            self.set_tags_answered(session, None, &remove, None)?;
            return Ok(true);
        }
        if since.is_some() && marked == auto {
            return Ok(false);
        }
        let mut set = serde_json::Map::new();
        set.insert(ARCHIVED_TAG.into(), Value::String(since.unwrap_or_else(|| now.to_string())));
        if auto {
            set.insert(ARCHIVED_BY_TAG.into(), Value::String(ARCHIVED_BY_AUTO.into()));
        }
        self.set_tags_answered(session, Some(&set), &[], None)?;
        Ok(true)
    }

    /// Whether a pass may archive `session`, inactive since before `cutoff` (Unix ms), or why
    /// not (module docs).
    pub(super) fn inactive_archivable(
        &self,
        session: &Session,
        cutoff: u64,
        now: u64,
    ) -> Result<(), &'static str> {
        session.read_meta(|m| {
            if has_tag(m, ARCHIVED_TAG, now) {
                return Err("archived");
            }
            if KEPT_TAGS.iter().any(|tag| has_tag(m, tag, now)) {
                return Err("kept");
            }
            if m.updated_at > cutoff {
                return Err("recent");
            }
            if matches!(m.status, SessionStatus::Running | SessionStatus::Waiting) {
                return Err("working");
            }
            Ok(())
        })?;
        if self.archive_held(session) { Err("working") } else { Ok(()) }
    }

    /// Whether anything runs or waits in `session`, as the idle reaper reads it
    /// (`idle.rs` `idle_eligible`), whatever its status.
    pub(super) fn archive_held(&self, session: &Session) -> bool {
        self.archive_held_with(session, false)
    }

    /// [`Self::archive_held`]; `cold` reads the background processes from the table this daemon
    /// holds, never from the chat's log: a cold chat's log is in its archive, and a read of it
    /// brings it back. A chat is archived only with no process running (`coldable`), and
    /// nothing runs in one afterwards.
    pub(super) fn archive_held_with(&self, session: &Session, cold: bool) -> bool {
        let processes = || {
            if cold {
                self.running_processes_read(session) > 0
            } else {
                self.any_process_running(session)
            }
        };
        session.turn().is_some()
            || session.harness_turn.load(Ordering::SeqCst)
            || session.asks_in_flight.load(Ordering::SeqCst) > 0
            || self.secrets.waiting_in(&session.id)
            || session.queued() > 0
            || !session.pending_permissions().is_empty()
            || processes()
            || session.subagents.lock().unwrap_or_else(|e| e.into_inner()).background_running() > 0
            || session.agent_requests.load(Ordering::SeqCst) > 0
            || self.continuation_pending(session)
            || session.work_below_since.lock().is_ok_and(|v| *v != 0)
            || session.moving().is_some()
            || session.loading.load(Ordering::SeqCst)
            || session.purged.load(Ordering::SeqCst)
            || session.replaced.load(Ordering::SeqCst)
    }

    /// One automatic pass at `now`: archives every chat inactive for longer than `after`, at
    /// most [`PASS_MAX`], and answers how many.
    pub(crate) fn inactive_archive_pass(&self, after: std::time::Duration, now: u64) -> usize {
        let cutoff = now.saturating_sub(u64::try_from(after.as_millis()).unwrap_or(u64::MAX));
        let mut archived = 0;
        for session in self.session_handles() {
            if archived >= PASS_MAX || self.shutting_down() {
                break;
            }
            if self.inactive_archivable(&session, cutoff, now).is_err() {
                continue;
            }
            match self.set_archived(&session, true, true) {
                Ok(true) => archived += 1,
                Ok(false) => {}
                Err(e) => tracing::warn!(session = %session.id, "inactive archive: {}", e.message),
            }
        }
        if archived > 0 {
            tracing::info!("inactive archive: {archived} chats inactive for {after:?}");
        }
        archived
    }

    /// The daemon's one inactive-archive worker (module docs): a pass [`FIRST_PASS_AFTER`] from
    /// when the setting is first seen on, then every [`PASS_EVERY`], while it is on. While it is
    /// off (the default) no timer: the setting is read again when the settings file changes, so
    /// an idle daemon does not wake for it (it woke 60 s after start and every 10 minutes,
    /// `tests/daemon_idle.rs`).
    pub(crate) fn inactive_archive_worker(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        let mut settings = self.settings_changes.subscribe();
        self.scope.spawn_until_cancelled("inactive-archive", async move {
            let mut wait = FIRST_PASS_AFTER;
            loop {
                // Marked seen before the read: a change after it ends the wait below at once.
                settings.borrow_and_update();
                let on = tokio::task::spawn_blocking(|| archive_after_now().is_some());
                if !on.await.unwrap_or(false) {
                    if settings.changed().await.is_err() {
                        return;
                    }
                    continue;
                }
                tokio::time::sleep(wait).await;
                wait = PASS_EVERY;
                let Some(hub) = weak.upgrade() else { return };
                if hub.shutting_down() {
                    return;
                }
                // The settings file and each archive's save are disk work.
                let pass = tokio::task::spawn_blocking(move || {
                    if let Some(after) = archive_after_now() {
                        hub.inactive_archive_pass(after, now_ms());
                    }
                });
                if let Err(e) = pass.await {
                    tracing::warn!("inactive archive pass: {e}");
                }
            }
        });
    }
}

#[cfg(test)]
#[path = "inactive_archive_tests.rs"]
mod tests;
