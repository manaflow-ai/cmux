//! Part of `Hub`; see `hub/mod.rs`. A done chat's lifecycle: archived, cold, then offloaded.
//!
//! Leo, 2026-11-27: "if things are completed/idle we should just be moving them off to r2 if we
//! really want to keep the session histories and whatnot".
//!
//! With `agents.chats.lifecycle` true (off by default; the fleet turns it on), a pass
//! [`FIRST_PASS_AFTER`] after the daemon read its chats, then every [`PASS_EVERY`], and
//! [`CLOSE_GRACE`] after any chat closes, takes every done chat through three steps that already
//! exist: the `archived` tag with `archivedBy=lifecycle` (off the lists, `inactive_archive.rs`),
//! the cold archive (`cold_archive.rs`), then the offload to cloud history when it is set up
//! (`cloud_offload.rs`'s store call, which uploads, reads back, and only then replaces `cold.zst`
//! with its stub; with no cloud history nothing leaves this disk and nothing is removed). Each
//! chat a pass takes is one line of `lifecycle.jsonl` in the acpmux home.
//!
//! Done ([`Hub::lifecycle_done`]) is closed (a close record, or the closed status), or idle since
//! its last turn ended (`lastTurn.endedAt`, else `createdAt`; never `updatedAt`, which every tag
//! and peer write moves) for `agents.chats.lifecycleIdleHours` (default 24). Never done while:
//! something runs or waits in it (the inactive archive's `archive_held`, an agent, a host, a
//! client), it holds a lease (`acpmux.sessionHold=on`, `fleet-pause.held`), its goal is not done,
//! a pull request it opened is still open (not merged or closed by any chat's `gh`, opened within
//! the review queue's window), it is a coordinator (by name, or any live chat reports to it), it
//! is a person's own chat (created by a person, on a person's screen, or with no creator kept:
//! a fork or a chat from before creators were kept, skipped as `no-creator`), or it is pinned,
//! starred, a side chat or an aside.
//!
//! `_acpmux/lifecycle {dryRun?}` (`acpmux daemon lifecycle [--dry-run] [--json]`) runs one pass
//! now, whatever the setting. `acpmux restore ID` brings one back.

use super::*;
use std::collections::{BTreeMap, HashSet};

/// Whether done chats are archived and offloaded on their own.
pub(crate) const SETTING_ON: &str = "agents.chats.lifecycle";
/// After how many hours with no turn an open chat is done.
pub(crate) const SETTING_HOURS: &str = "agents.chats.lifecycleIdleHours";
const DEFAULT_HOURS: u64 = 24;
/// [`super::inactive_archive::ARCHIVED_BY_TAG`]'s value for a chat this pass archived.
pub(crate) const ARCHIVED_BY_LIFECYCLE: &str = "lifecycle";
/// The log of every chat a pass took, in the acpmux home.
pub(crate) const LOG: &str = "lifecycle.jsonl";
const PASS_EVERY: std::time::Duration = std::time::Duration::from_secs(24 * 60 * 60);
const FIRST_PASS_AFTER: std::time::Duration = std::time::Duration::from_secs(60);
/// After a close: its agent exits and its last records land first.
const CLOSE_GRACE: std::time::Duration = std::time::Duration::from_secs(10 * 60);
/// The most chats one pass takes; the rest go on the next.
const PASS_MAX: usize = 200;
/// Tags that keep a chat as it is: pinned, starred, side chats and asides.
const KEPT_TAGS: [&str; 5] = ["pinned", "starred", "side", "aside", "lane.pinned"];
/// Lease tags, with the value that holds (None: any value).
const HOLD_TAGS: [(&str, Option<&str>); 2] =
    [(super::session_hold::TAG, Some("on")), ("fleet-pause.held", None)];

/// How long an open chat goes with no turn before it is done; None when the setting is off.
pub(crate) fn idle_after(doc: &Value) -> Option<std::time::Duration> {
    if crate::user_settings::value(doc, SETTING_ON) != Some(Value::Bool(true)) {
        return None;
    }
    Some(idle_hours(doc))
}

fn idle_hours(doc: &Value) -> std::time::Duration {
    let hours = match crate::user_settings::value(doc, SETTING_HOURS) {
        Some(Value::Number(n)) => n.as_u64(),
        Some(Value::String(s)) => {
            let s = s.trim();
            s.strip_suffix('h').unwrap_or(s).parse::<u64>().ok()
        }
        _ => None,
    }
    .filter(|h| *h > 0)
    .unwrap_or(DEFAULT_HOURS);
    std::time::Duration::from_secs(hours.saturating_mul(3600))
}

fn settings_doc() -> Option<Value> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    }
}

fn idle_after_now() -> Option<std::time::Duration> {
    settings_doc().as_ref().and_then(idle_after)
}

/// What `_acpmux/lifecycle` is asked.
#[derive(Debug, Default, Clone)]
pub struct LifecycleRequest {
    /// Only list what would go.
    pub dry_run: bool,
}

fn has_tag(meta: &SessionMeta, key: &str, now: u64) -> bool {
    meta.tags.get(key).is_some_and(|tag| tag.expires_at.is_none_or(|at| at > now))
}

/// When `meta`'s chat last did anything of its own: its last turn's end, else its start.
pub(crate) fn last_active(meta: &SessionMeta) -> u64 {
    meta.last_turn
        .as_ref()
        .and_then(|t| t.get("endedAt"))
        .and_then(Value::as_u64)
        .unwrap_or(meta.created_at)
}

/// Whether `meta` names a pull request still open: opened (or, with no time kept, created)
/// within the review queue's window, and not merged or closed by this chat or any other
/// (`closed`).
pub(crate) fn open_pull_request(
    meta: &SessionMeta,
    now: u64,
    closed: &dyn Fn(&str) -> bool,
) -> bool {
    meta.pull_requests.iter().any(|url| {
        if meta.closed_pull_requests.iter().any(|c| c == url) || closed(url) {
            return false;
        }
        let at = meta.pull_request_times.get(url).copied().unwrap_or(meta.created_at);
        now.saturating_sub(at) < super::review_queue::PR_WINDOW_MS
    })
}

/// One chat a pass took: its `lifecycle.jsonl` line and report row.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Taken {
    pub id: String,
    pub name: String,
    pub reason: String,
    pub bytes_before: u64,
    pub bytes_after: u64,
    pub offloaded: bool,
    pub at: u64,
}

impl Hub {
    /// The chats any live chat reports to (`lane.reportsTo`): coordinators, never taken.
    fn lifecycle_leaders(&self) -> HashSet<String> {
        self.live_session_handles()
            .iter()
            .filter_map(|s| s.read_meta(|m| m.tags.get(REPORTS_TO_TAG).map(|t| t.value.clone())))
            .collect()
    }

    /// Whether `session` is done (module docs): why (`closed`, `idle-24h`), or why it is kept.
    pub(super) fn lifecycle_done(
        &self,
        session: &Session,
        idle: std::time::Duration,
        now: u64,
        leaders: &HashSet<String>,
        hosted: &HashSet<String>,
    ) -> Result<String, &'static str> {
        let meta = session.meta();
        if meta.pinned
            || super::history_delete::kept_by_person(&meta)
            || KEPT_TAGS.iter().any(|t| has_tag(&meta, t, now))
        {
            return Err("kept");
        }
        if HOLD_TAGS.iter().any(|(key, held)| {
            meta.tags.get(*key).is_some_and(|t| {
                t.expires_at.is_none_or(|at| at > now) && held.is_none_or(|v| t.value == v)
            })
        }) {
            return Err("held");
        }
        if super::cache_compact::coordinator_name(&meta.name)
            || meta.tags.get("role").is_some_and(|t| t.value.contains("coord"))
            || leaders.contains(&session.id)
        {
            return Err("coordinator");
        }
        match meta.created_by.as_ref().map(|c| c.kind) {
            Some(crate::store::CreatorKind::Person) => return Err("person"),
            // A fork, a moved-in chat, or one from before creators were kept: maybe the
            // person's, so kept (`Hub::for_a_person` reads it the same way).
            None => return Err("no-creator"),
            Some(_) if self.shown(session) => return Err("person"),
            Some(_) => {}
        }
        if meta.goal.as_ref().is_some_and(|g| g.status != crate::goal::GoalStatus::Done) {
            return Err("goal");
        }
        if open_pull_request(&meta, now, &|url| self.review_index.pr_closed(url)) {
            return Err("pr");
        }
        if !matches!(meta.status, SessionStatus::Closed | SessionStatus::Idle) {
            return Err("working");
        }
        let no_agent = session.child.try_lock().is_ok_and(|child| child.is_none());
        if !no_agent || hosted.contains(&session.id) {
            return Err("agent");
        }
        if session.attached.load(Ordering::SeqCst) > 0 {
            return Err("attached");
        }
        if self.archive_held_with(session, meta.cold.is_some())
            || session.purging.load(Ordering::SeqCst)
        {
            return Err("working");
        }
        if meta.close.is_some() || meta.status == SessionStatus::Closed {
            return Ok("closed".into());
        }
        let idle_ms = u64::try_from(idle.as_millis()).unwrap_or(u64::MAX);
        if now.saturating_sub(last_active(&meta)) < idle_ms {
            return Err("recent");
        }
        Ok(format!("idle-{}h", idle.as_secs() / 3600))
    }

    /// Whether a pass already took `session` as far as it goes here: archived and cold, and
    /// offloaded when `cloud` (or never offloadable here).
    fn lifecycle_finished(&self, session: &Session, now: u64, cloud: bool) -> bool {
        let (archived, cold) = session.read_meta(|m| {
            (has_tag(m, super::inactive_archive::ARCHIVED_TAG, now), m.cold.is_some())
        });
        archived && cold && self.store.is_cold(&session.id) && (!cloud || self.offloaded(session))
    }

    /// The chat's archive went to cloud history: cold, and no local archive left to offload.
    fn offloaded(&self, session: &Session) -> bool {
        self.store.is_cold(&session.id) && self.store.offloaded(&session.id)
    }

    /// Takes one done chat: archived (unless it is already, by anyone), cold, offloaded when
    /// cloud history is set up. Under its turn lock, and only while still done.
    fn lifecycle_take(
        &self,
        session: &Arc<Session>,
        reason: &str,
        hosted: &HashSet<String>,
    ) -> Result<Taken, &'static str> {
        let now = now_ms();
        let Ok(_turn) = session.turn_lock.try_lock() else { return Err("busy") };
        let archived =
            session.read_meta(|m| has_tag(m, super::inactive_archive::ARCHIVED_TAG, now));
        if !archived {
            // The tag is a logged record: a cold chat's log comes back first, whole, so the
            // record lands in it, and goes cold again below.
            if session.meta().cold.is_some()
                && let Err(e) = self.rehydrate_chat(session)
            {
                tracing::warn!(session = %session.id, "lifecycle: rehydrate: {e:#}");
                return Err("error");
            }
            use super::inactive_archive::{ARCHIVED_BY_TAG, ARCHIVED_TAG};
            let mut set = serde_json::Map::new();
            set.insert(ARCHIVED_TAG.into(), Value::String(now.to_string()));
            set.insert(ARCHIVED_BY_TAG.into(), Value::String(ARCHIVED_BY_LIFECYCLE.into()));
            if let Err(e) = self.set_tags_answered(session, Some(&set), &[], None) {
                tracing::warn!(session = %session.id, "lifecycle: archive: {}", e.message);
                return Err("error");
            }
        }
        let preview = match self.cold_archive_chat(session, None, hosted) {
            Ok(preview) => Some(preview),
            Err("archived") => session.meta().cold,
            Err(why) => {
                tracing::info!(session = %session.id, "lifecycle: archived, not cold: {why}");
                None
            }
        };
        let (bytes_before, mut bytes_after) =
            preview.as_ref().map_or((0, 0), |p| (p.bytes_before, p.bytes_after));
        let mut offloaded = false;
        if preview.is_some() {
            match crate::qos::background(|| self.store.offload_cold(&session.id)) {
                Ok(Some(freed)) => {
                    offloaded = true;
                    bytes_after = bytes_after.saturating_sub(freed);
                }
                Ok(None) => offloaded = self.offloaded(session),
                Err(e) => tracing::warn!(session = %session.id, "lifecycle: offload: {e:#}"),
            }
        }
        if offloaded && bytes_after == preview.as_ref().map_or(0, |p| p.bytes_after) {
            // Offloaded before this pass: only the search copy and stub stay here.
            bytes_after = 0;
        }
        Ok(Taken {
            id: session.id.clone(),
            name: session.meta().name,
            reason: reason.to_owned(),
            bytes_before,
            bytes_after,
            offloaded,
            at: now_ms(),
        })
    }

    /// One pass at `now` over every chat: the report `{dryRun, idleHours, cloud, archived,
    /// offloaded, bytesBefore, bytesAfter, bytesFreed, chats[], skipped{why: n}}`, and a
    /// `lifecycle.jsonl` line in `log` per chat taken. Blocking (disk and the upload).
    pub(crate) fn lifecycle_pass(
        &self,
        idle: std::time::Duration,
        dry_run: bool,
        log: Option<&std::path::Path>,
    ) -> Value {
        let now = now_ms();
        if let Err(e) = crate::agent_host::load_records(&crate::agent_host::hosts_dir()) {
            tracing::warn!("lifecycle: agent host records: {e:#}");
            return json!({"dryRun": dry_run, "error": format!("agent host records: {e:#}")});
        }
        let hosted = Self::live_host_sessions();
        let leaders = self.lifecycle_leaders();
        let cloud = self.store.cloud_configured();
        let mut sessions = self.session_handles();
        sessions.sort_by_key(|s| s.read_meta(last_active));
        let (mut archived, mut offloaded, mut before, mut after) = (0u64, 0u64, 0u64, 0u64);
        let mut chats = Vec::new();
        let mut skipped: BTreeMap<String, u64> = BTreeMap::new();
        for session in sessions {
            if self.shutting_down() {
                break;
            }
            if self.lifecycle_finished(&session, now, cloud) {
                *skipped.entry("done".into()).or_default() += 1;
                continue;
            }
            let reason = match self.lifecycle_done(&session, idle, now, &leaders, &hosted) {
                Ok(reason) => reason,
                Err(why) => {
                    *skipped.entry(why.into()).or_default() += 1;
                    continue;
                }
            };
            if archived as usize >= PASS_MAX {
                *skipped.entry("next pass".into()).or_default() += 1;
                continue;
            }
            if dry_run {
                let meta = session.meta();
                archived += 1;
                let bytes = meta.cold.as_ref().map(|c| (c.bytes_before, c.bytes_after));
                before += bytes.map_or(0, |b| b.0);
                after += bytes.map_or(0, |b| b.1);
                if chats.len() < PASS_MAX {
                    chats.push(json!({
                        "id": session.id, "name": meta.name, "reason": reason,
                        "cold": meta.cold.is_some(), "wouldOffload": cloud,
                    }));
                }
                continue;
            }
            let taken = match self.lifecycle_take(&session, &reason, &hosted) {
                Ok(taken) => taken,
                Err(why) => {
                    *skipped.entry(why.into()).or_default() += 1;
                    continue;
                }
            };
            archived += 1;
            offloaded += u64::from(taken.offloaded);
            before += taken.bytes_before;
            after += taken.bytes_after;
            if let Some(log) = log
                && let Err(e) = append_line(log, &taken)
            {
                tracing::warn!("lifecycle log {} not written: {e:#}", log.display());
            }
            if chats.len() < PASS_MAX {
                chats.push(serde_json::to_value(&taken).unwrap_or(Value::Null));
            }
        }
        if offloaded > 0 {
            if let Err(e) = self.store.register_cloud_root() {
                tracing::warn!("lifecycle: cloud history root: {e:#}");
            }
        }
        if archived > 0 && !dry_run {
            tracing::info!(
                "lifecycle: {archived} chats archived, {offloaded} offloaded, {before} bytes to {after}"
            );
        }
        json!({
            "dryRun": dry_run,
            "idleHours": idle.as_secs() / 3600,
            "cloud": cloud,
            "archived": archived,
            "offloaded": offloaded,
            "bytesBefore": before,
            "bytesAfter": after,
            "bytesFreed": before.saturating_sub(after),
            "chats": chats,
            "skipped": skipped,
        })
    }

    /// `_acpmux/lifecycle`: one pass now, by the setting's hours (the default's when it is off,
    /// so a person can run one by hand).
    pub async fn lifecycle_now(self: &Arc<Self>, req: LifecycleRequest) -> Result<Value, RpcError> {
        let hub = self.clone();
        tokio::task::spawn_blocking(move || {
            let idle = settings_doc()
                .as_ref()
                .map_or(std::time::Duration::from_secs(DEFAULT_HOURS * 3600), idle_hours);
            let log = crate::config::home().join(LOG);
            hub.lifecycle_pass(idle, req.dry_run, Some(&log))
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))
    }

    /// A chat closed: a pass [`CLOSE_GRACE`] later, when the setting is on.
    pub(super) fn lifecycle_wake(&self) {
        self.lifecycle_wake.notify_one();
    }

    /// The daemon's one lifecycle worker (module docs). While the setting is off, no timer: the
    /// setting is read again when the settings file changes.
    pub(crate) fn lifecycle_worker(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        let mut settings = self.settings_changes.subscribe();
        let wake = self.lifecycle_wake.clone();
        self.scope.spawn_until_cancelled("session-lifecycle", async move {
            let mut wait = FIRST_PASS_AFTER;
            loop {
                settings.borrow_and_update();
                let on = tokio::task::spawn_blocking(|| idle_after_now().is_some());
                if !on.await.unwrap_or(false) {
                    if settings.changed().await.is_err() {
                        return;
                    }
                    continue;
                }
                tokio::select! {
                    () = tokio::time::sleep(wait) => wait = PASS_EVERY,
                    () = wake.notified() => {
                        tokio::time::sleep(CLOSE_GRACE).await;
                    }
                    changed = settings.changed() => {
                        if changed.is_err() {
                            return;
                        }
                        continue;
                    }
                }
                let Some(hub) = weak.upgrade() else { return };
                if hub.shutting_down() {
                    return;
                }
                let pass = tokio::task::spawn_blocking(move || {
                    if let Some(idle) = idle_after_now() {
                        let log = crate::config::home().join(LOG);
                        hub.lifecycle_pass(idle, false, Some(&log));
                    }
                });
                if let Err(e) = pass.await {
                    tracing::warn!("lifecycle pass: {e}");
                }
            }
        });
    }

    /// `acpmux restore ID` (`_acpmux/lifecycle {restore}`): back in the lists (unarchived, and
    /// undeleted when deleted), and its log back on this disk, fetched from cloud history when it
    /// went there. What changed: `{sessionId, unarchived, rehydrated}`.
    pub(crate) async fn lifecycle_restore(
        self: &Arc<Self>,
        session: Arc<Session>,
    ) -> Result<Value, RpcError> {
        let deleted =
            session.read_meta(|m| m.tags.contains_key(super::history_delete::DELETED_TAG));
        if deleted {
            self.history_restore(&session).map_err(|e| RpcError::internal(e.to_string()))?;
        }
        let unarchived = self.set_archived(&session, false, false)? || deleted;
        let hub = self.clone();
        let chat = session.clone();
        let rehydrated = tokio::task::spawn_blocking(move || hub.rehydrate_chat(&chat))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
            .map_err(|e| RpcError::internal(format!("{e:#}")))?;
        Ok(json!({"sessionId": session.id, "unarchived": unarchived, "rehydrated": rehydrated}))
    }
}

fn append_line(path: &std::path::Path, taken: &Taken) -> anyhow::Result<()> {
    use std::io::Write as _;
    let mut bytes = serde_json::to_vec(taken)?;
    bytes.push(b'\n');
    #[cfg(unix)]
    let mut file = crate::config::private_state_append(path)?;
    #[cfg(windows)]
    let mut file = {
        crate::config::refuse_lost_home(path)?;
        crate::owner_only::open_append(path)?
    };
    file.write_all(&bytes)?;
    Ok(())
}

#[cfg(test)]
#[path = "session_lifecycle_tests.rs"]
mod tests;
