//! Part of `Hub`; see `hub/mod.rs`. Cold archive of old agent chats.
//!
//! Leo, 2026-11-09: "why the hell is it even so big anyways? just bc of claude? is there a way for
//! us to compress super hard? potentially auto compress old history to save disk? some sort of
//! cold archival thing, like a TRUE \"archive chat\" type thing that you can stil preview a sliver
//! of but otherwise just... like, essentially put the same kinda scrutiny we do on RAM as we do for
//! disk usage"
//!
//! A chat with no agent and nothing under way can have its log moved into one zstd file
//! (`store/cold.rs`). Before that, its preview is read from the log: its message count and last
//! [`PREVIEW_MESSAGES`] messages, each cut to [`PREVIEW_CHARS`] (masked before the cut,
//! `preview_text`; a peer reads every one masked, `server/peer_text.rs`). The preview and the
//! bytes before and after go in `session.json` (`SessionMeta::cold`), and the chat's summary
//! carries them as `coldArchive`, so the list shows an archived chat as before, from
//! `session.json` alone: listing and startup cost the same however many chats are archived or how
//! big they were. The daemon's
//! startup reads no archived chat's log (`load_logs`); there is nothing in it to restore (an
//! archived chat had no turn, queue or agent).
//!
//! The log comes back on its own: opening the chat (`session_log_at`), a replay
//! (`scan_events`, `events`) or any other read of the log rehydrates it, byte for byte, and the
//! preview is dropped. Any rehydrate, on any path (a search's read through the store too), calls
//! the store's hook (`watch_rehydrates`), and `rehydrate_worker` drops that chat's preview from
//! `session.json` right after; one a crash left behind goes at the next start (`cold_at_start`).
//! Each change of a chat's archive goes to the watchers as a `session_changed` (`cold_changed`):
//! no record is logged for it, since a write to the log brings the archive back.
//!
//! `_acpmux/cold_archive {sessionId, archived}` archives one chat now (`archived: true`) or brings
//! it back (`false`). With `agents.chats.coldArchive` on (off by default), the retention worker
//! (`hub/retention.rs`, same wakes and stop condition) also archives every chat idle for
//! `agents.chats.coldArchiveAfterDays` (default 30): no record logged and no metadata change in
//! that long. The settings are read from the settings file at each pass.

use super::*;
use crate::store::{ColdPreview, PreviewMessage};

/// The `dir` and `kind` of the unlogged hub event that says a chat's archive came or went
/// (`cold_changed`); `server::deliver` sends it as a `session_changed`.
pub(crate) const COLD_CHANGED: &str = "cold_archive";

/// The messages a preview keeps.
const PREVIEW_MESSAGES: usize = 3;
/// The characters a preview keeps of each.
const PREVIEW_CHARS: usize = 280;
/// How much of a longer message is scanned for secrets before its cut: past the cut, so a secret
/// that starts before it is still whole when it is masked.
const PREVIEW_SCAN_CHARS: usize = PREVIEW_CHARS + 4096;
/// Whether idle chats are archived on their own.
pub(crate) const SETTING_ON: &str = "agents.chats.coldArchive";
/// After how many idle days.
pub(crate) const SETTING_DAYS: &str = "agents.chats.coldArchiveAfterDays";
const DEFAULT_DAYS: u64 = 30;

/// How long a chat stays idle before a pass archives it, from the settings document; None when
/// automatic archiving is off.
pub(crate) fn auto_after(doc: &Value) -> Option<std::time::Duration> {
    if crate::user_settings::value(doc, SETTING_ON) != Some(Value::Bool(true)) {
        return None;
    }
    let days = crate::user_settings::value(doc, SETTING_DAYS)
        .and_then(|v| v.as_u64())
        .filter(|days| *days > 0)
        .unwrap_or(DEFAULT_DAYS);
    Some(std::time::Duration::from_secs(days.saturating_mul(86_400)))
}

/// [`auto_after`] of the settings file as it is now.
fn auto_after_now() -> Option<std::time::Duration> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => auto_after(&doc),
        _ => None,
    }
}

/// A preview's messages: each of `entries` (the log's last ones) cut to [`PREVIEW_CHARS`].
fn preview_messages(
    entries: impl IntoIterator<Item = crate::session_search::Entry>,
) -> Vec<PreviewMessage> {
    entries
        .into_iter()
        .map(|entry| {
            let role = serde_json::to_value(entry.role)
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default();
            PreviewMessage { role, text: preview_text(&entry.text), at: entry.at }
        })
        .collect()
}

/// One message of a preview: whole when it fits, else its first [`PREVIEW_CHARS`], masked before
/// the cut (`secret_scan`) as a list row's long title is (`hub/views.rs`, `summary_title`): a
/// secret the cut would split is masked whole, never left as a head a peer's masking no longer
/// knows (third review of #39141, F1). A whole message keeps its raw text, which a peer reads
/// masked (`server/peer_text.rs`).
fn preview_text(text: &str) -> String {
    if text.chars().nth(PREVIEW_CHARS).is_none() {
        return text.to_owned();
    }
    let head: String = text.chars().take(PREVIEW_SCAN_CHARS).collect();
    let mut cut: String = crate::secret_scan::mask(&head).chars().take(PREVIEW_CHARS).collect();
    cut.push('…');
    cut
}

impl Hub {
    /// `_acpmux/cold_archive`: archive `session` now, or bring its log back.
    pub async fn cold_archive_request(
        self: &Arc<Self>,
        session: Arc<Session>,
        archived: bool,
    ) -> Result<Value, RpcError> {
        let hub = self.clone();
        let s = session.clone();
        let done = tokio::task::spawn_blocking(move || {
            if archived {
                let hosted = Self::live_host_sessions();
                hub.cold_archive_chat(&s, None, &hosted).map(|_| ()).map_err(|why| {
                    RpcError::new(-32000, format!("the chat is not archived: {why}"))
                })
            } else {
                hub.rehydrate_chat(&s).map(|_| ()).map_err(|e| RpcError::internal(format!("{e:#}")))
            }
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
        done?;
        Ok(self.session_summary(&session))
    }

    /// Archives `session`'s log, when nothing may use it now and, with `cutoff` (ms), it was idle
    /// since then. Its preview, or why not.
    pub(crate) fn cold_archive_chat(
        &self,
        session: &Arc<Session>,
        cutoff: Option<u64>,
        hosted: &std::collections::HashSet<String>,
    ) -> Result<ColdPreview, &'static str> {
        let seen = self.coldable(session, cutoff, hosted)?;
        // The whole log is read once for its messages; only the last few are held.
        let mut count = 0u64;
        let mut entries = std::collections::VecDeque::with_capacity(PREVIEW_MESSAGES + 1);
        let read = self.store.text_entries(&session.id, &mut |entry| {
            count += 1;
            entries.push_back(entry);
            if entries.len() > PREVIEW_MESSAGES {
                entries.pop_front();
            }
        });
        if let Err(e) = read {
            tracing::warn!(session = %session.id, "cold archive: preview: {e:#}");
            return Err("error");
        }
        let (messages, last) = (count, preview_messages(entries));
        let staged = match self.store.stage_cold(&session.id) {
            Ok(Some(staged)) => staged,
            Ok(None) => return Err("no log"),
            Err(e) => {
                tracing::warn!(session = %session.id, "cold archive: {e:#}");
                return Err("error");
            }
        };
        let stats = staged.stats;
        let committed = {
            let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
            if self.still_coldable(session, seen) {
                self.store.commit_cold(&session.id, staged)
            } else {
                Ok(false)
            }
        };
        match committed {
            Ok(true) => {}
            Ok(false) => return Err("changed"),
            Err(e) => {
                tracing::warn!(session = %session.id, "cold archive: {e:#}");
                return Err("error");
            }
        }
        #[cfg(test)]
        after_cold_commit(self, session);
        let preview = ColdPreview {
            archived_at: now_ms(),
            messages,
            bytes_before: stats.bytes_before,
            bytes_after: stats.bytes_after,
            last,
        };
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).cold = Some(preview.clone());
        // A read may have brought the log back since the commit, and the worker found no preview
        // to drop then (second review of #39141: the chat stayed marked archived with its log
        // back). The preview is in before this look: a rehydrate that removes the archive after
        // it wakes the worker after it too, which drops the preview then.
        if !self.store.is_cold(&session.id) {
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).cold = None;
            self.cold_changed(session);
            return Err("changed");
        }
        // A failed save leaves the chat archived without its preview: it lists as before, and its
        // first read brings it back.
        self.save_meta(session);
        self.cold_changed(session);
        tracing::info!(
            session = %session.id,
            before = stats.bytes_before,
            after = stats.bytes_after,
            "cold-archived a chat"
        );
        Ok(preview)
    }

    /// Brings `session`'s log back from its cold archive and drops its preview. Whether it was
    /// archived.
    pub(crate) fn rehydrate_chat(&self, session: &Session) -> anyhow::Result<bool> {
        let back = self.store.rehydrate(&session.id)?;
        let had = session.meta.lock().unwrap_or_else(|e| e.into_inner()).cold.take().is_some();
        if had {
            self.save_meta(session);
        }
        if back || had {
            self.cold_changed(session);
        }
        Ok(back || had)
    }

    /// Tells the watchers `session`'s row changed: its `coldArchive` came or went. Not a logged
    /// record (an append would bring the archive back), so it has no seq.
    pub(super) fn cold_changed(&self, session: &Session) {
        let _ = self.events.send(HubEvent {
            session_id: session.id.clone(),
            record: Arc::new(EventRecord {
                seq: 0,
                at: now_ms(),
                dir: COLD_CHANGED.into(),
                kind: COLD_CHANGED.into(),
                msg: json!({}),
                host_seq: None,
            }),
            remote: None,
            update_line: Default::default(),
            row: Default::default(),
        });
    }

    /// Installs the store's rehydrate hook: the chat's id goes in `cold_rehydrated` and the
    /// worker wakes. The hook runs inside the store's locks (an append's, a read's), so it takes
    /// only that set's lock, which nothing else holds across a call.
    pub(super) fn watch_rehydrates(&self) {
        let (set, wake) = (self.cold_rehydrated.clone(), self.cold_wake.clone());
        self.store.on_rehydrate(Arc::new(move |id: &str| {
            set.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned());
            wake.notify_one();
        }));
    }

    /// Drops the preview of every chat the store brought back since the last call, in memory and
    /// in `session.json`. How many it dropped.
    pub(crate) fn settle_rehydrated(&self) -> usize {
        let ids =
            std::mem::take(&mut *self.cold_rehydrated.lock().unwrap_or_else(|e| e.into_inner()));
        let mut dropped = 0;
        for id in ids {
            let live = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned();
            let Some(session) = live else { continue };
            // A chat with a preview is never archived again until the preview goes
            // (`coldable`), so one still cold here was not brought back after all.
            if self.store.is_cold(&id) {
                continue;
            }
            let had = session.meta.lock().unwrap_or_else(|e| e.into_inner()).cold.take().is_some();
            if had {
                self.save_meta(&session);
                self.cold_changed(&session);
                dropped += 1;
            }
        }
        dropped
    }

    /// The worker that drops a rehydrated chat's preview (`settle_rehydrated`), one per daemon:
    /// it waits on the hook's wake, holds the hub weakly, and ends when the daemon shuts down (its
    /// stop condition: the shutdown wakes it, `shutdown_sessions`) or the hub is gone.
    pub(super) fn rehydrate_worker(self: &Arc<Self>) {
        let hub = Arc::downgrade(self);
        let wake = self.cold_wake.clone();
        self.scope.spawn_until_cancelled("rehydrate-worker", async move {
            loop {
                wake.notified().await;
                let Some(hub) = hub.upgrade() else { return };
                if hub.shutting_down() {
                    return;
                }
                let h = hub.clone();
                drop(hub);
                if let Err(e) = tokio::task::spawn_blocking(move || h.settle_rehydrated()).await {
                    tracing::warn!("cold archive: drop rehydrated previews: {e}");
                }
            }
        });
    }

    /// At the daemon's start (`load_logs`): whether `session` is archived, one look at the disk
    /// for a chat with a preview and none for any other. A preview whose log is back is dropped.
    pub(super) fn cold_at_start(&self, session: &Session) -> bool {
        if session.meta.lock().unwrap_or_else(|e| e.into_inner()).cold.is_none() {
            return false;
        }
        if self.store.is_cold(&session.id) {
            return true;
        }
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).cold = None;
        self.save_meta(session);
        false
    }

    /// [`Self::rehydrate_chat`] for a chat about to be read, when its metadata says it is
    /// archived; a failure is logged, and the read that follows fails on its own.
    pub(super) fn warm_chat(&self, session: &Session) {
        if session.meta.lock().unwrap_or_else(|e| e.into_inner()).cold.is_none() {
            return;
        }
        if let Err(e) = self.rehydrate_chat(session) {
            tracing::warn!(session = %session.id, "rehydrate a cold-archived chat: {e:#}");
        }
    }

    /// [`Self::warm_chat`] by id, for a chat the hub holds.
    pub(super) fn warm_chat_id(&self, id: &str) {
        let live = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        if let Some(session) = live {
            self.warm_chat(&session);
        }
    }

    /// Whether `session` may be archived now: its `updated_at`, or why not. As a retention pass's
    /// `retainable`, but an idle chat counts as well as a closed one.
    fn coldable(
        &self,
        session: &Session,
        cutoff: Option<u64>,
        hosted: &std::collections::HashSet<String>,
    ) -> Result<u64, &'static str> {
        let meta = session.meta();
        if meta.cold.is_some() || self.store.is_cold(&session.id) {
            return Err("archived");
        }
        if !matches!(meta.status, SessionStatus::Closed | SessionStatus::Idle) {
            return Err("open");
        }
        if cutoff.is_some_and(|cutoff| self.age(session, &meta) > cutoff) {
            return Err("recent");
        }
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
            || self.has_auto_resume_mark(session)
        {
            return Err("busy");
        }
        Ok(meta.updated_at)
    }

    /// Under the chat's append lock, right before the archive goes in: nothing changed since
    /// `coldable` let it in (as retention's `untouched`).
    fn still_coldable(&self, session: &Session, seen: u64) -> bool {
        let meta = session.meta();
        matches!(meta.status, SessionStatus::Closed | SessionStatus::Idle)
            && meta.updated_at == seen
            && session.status_writes.load(Ordering::SeqCst) == 0
            && session.child.try_lock().is_ok_and(|child| child.is_none())
            && session.attached.load(Ordering::SeqCst) == 0
            && session.turn().is_none()
            && session.queued() == 0
            && !self.has_auto_resume_mark(session)
            && !session.purged.load(Ordering::SeqCst)
            && !session.replaced.load(Ordering::SeqCst)
            && !session.loading.load(Ordering::SeqCst)
            && session.moving().is_none()
            && !self.importing.lock().unwrap_or_else(|e| e.into_inner()).contains(&session.id)
    }

    /// The automatic pass, on the retention worker (`hub/retention.rs`): every chat idle past
    /// the setting, oldest first, one at a time, stopping between two chats at a shutdown. A
    /// preview whose chat a store read brought back is dropped here. Nothing when the setting is
    /// off.
    pub(super) fn cold_pass(self: &Arc<Self>) {
        if let Some(after) = auto_after_now() {
            self.cold_pass_after(after);
        }
    }

    /// [`Self::cold_pass`] for chats idle longer than `after`: how many it archived.
    fn cold_pass_after(self: &Arc<Self>, after: std::time::Duration) -> u64 {
        let cutoff = now_ms().saturating_sub(u64::try_from(after.as_millis()).unwrap_or(u64::MAX));
        let hosted = Self::live_host_sessions();
        let mut sessions = self.sessions();
        sessions.sort_by_key(|s| s.meta().updated_at);
        let (mut archived, mut before, mut after_bytes) = (0u64, 0u64, 0u64);
        for session in sessions {
            if self.shutting_down() {
                break;
            }
            if session.meta().cold.is_some() {
                if !self.store.is_cold(&session.id) {
                    self.warm_chat(&session);
                }
                continue;
            }
            if let Ok(preview) = self.cold_archive_chat(&session, Some(cutoff), &hosted) {
                archived += 1;
                before += preview.bytes_before;
                after_bytes += preview.bytes_after;
            }
        }
        if archived > 0 {
            tracing::info!("cold archive: {archived} idle chats, {before} bytes to {after_bytes}");
        }
        archived
    }
}

#[cfg(test)]
thread_local! {
    /// Test seam (second review of #39141): runs right after an archive's commit, before its
    /// preview goes in.
    pub(super) static AFTER_COLD_COMMIT: std::cell::Cell<Option<fn(&Hub, &Session)>> =
        const { std::cell::Cell::new(None) };
}

/// Runs the `AFTER_COLD_COMMIT` seam, once.
#[cfg(test)]
fn after_cold_commit(hub: &Hub, session: &Session) {
    if let Some(f) = AFTER_COLD_COMMIT.take() {
        f(hub, session);
    }
}

#[cfg(test)]
#[path = "cold_archive_tests.rs"]
mod tests;
