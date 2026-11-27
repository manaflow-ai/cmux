//! Part of `Hub`; see `hub/mod.rs`. Deleting old chat history on a setting.
//!
//! The customization matrix row history-retention ("How long chat history is kept, or turn it
//! off"): Claude Code's `cleanupPeriodDays` and Codex's `history.persistence` say how long chat history is
//! kept. cmux compresses old chats (`cold_archive.rs`) and compacts closed chats' logs
//! (`retention.rs`) but kept every chat forever.
//!
//! With `agents.chats.autoDelete` on (`agents.chats.autoDeleteAfterDays`, 180 by default) or
//! `agents.chats.deleteHistoryAfterDays` set to a number of days (off and 0, the defaults, are
//! never: nothing is deleted), the retention worker (`hub/retention.rs`, same wakes, spacing and
//! stop condition) deletes every chat that is closed, or cold-archived and idle, and has had no
//! record logged and no change for that long.
//!
//! A delete is a tombstone first (cmuxterm-hq `docs/design/cold-storage-and-shared-tier.md`
//! section 5, "Tombstone: hidden from the list; local data and cloud copy kept for an undo
//! window"): the chat is archived, which every list already leaves out, and tagged
//! [`DELETED_TAG`] with when, its folder, log and cloud copy untouched. For [`UNDO_DAYS`] it is
//! in Recently deleted (`acpmux daemon history-delete --deleted`), and
//! [`Hub::history_restore`] (`--restore ID`), or an unarchive from any list (`tags.rs`), brings
//! it back. Only a tombstone that old, still closed and unused, is purged: the same delete as
//! `acpmux session rm` (`Hub::kill` with `purge`), its folder, log, cold archive, uploads and
//! ledger entry gone. A tombstoned chat that runs again (a prompt sent to it by id) is restored
//! by the next pass instead. A chat is never deleted while anything may use it
//! ([`Hub::history_deletable`]): it is
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
/// The design's switch (section 5): on, chats unchanged for [`AUTO_DAYS_SETTING`] days are
/// deleted; off (the default) leaves [`SETTING`] alone to decide.
pub(crate) const AUTO_SETTING: &str = "agents.chats.autoDelete";
/// After how many days [`AUTO_SETTING`] deletes; [`AUTO_DAYS_DEFAULT`] when absent.
pub(crate) const AUTO_DAYS_SETTING: &str = "agents.chats.autoDeleteAfterDays";
const AUTO_DAYS_DEFAULT: u64 = 180;
/// The tag a deleted chat carries until it is purged or restored, valued with when (Unix ms).
pub(crate) const DELETED_TAG: &str = "deleted";
/// Who deleted it: `auto` for the pass, `cli` for `acpmux daemon history-delete`.
pub(crate) const DELETED_BY_TAG: &str = "deletedBy";
/// [`ARCHIVED_BY_TAG`](super::inactive_archive::ARCHIVED_BY_TAG)'s value on the archive a
/// delete made, so a restore lifts that archive and keeps one the person made.
pub(crate) const ARCHIVED_BY_DELETE: &str = "delete";
/// How long a deleted chat can be restored before a pass purges it.
pub(crate) const UNDO_DAYS: u64 = 14;
const UNDO_MS: u64 = UNDO_DAYS * 86_400_000;

/// When `meta`'s chat was deleted (its [`DELETED_TAG`]), if it is.
pub(crate) fn deleted_at(meta: &SessionMeta) -> Option<u64> {
    meta.tags.get(DELETED_TAG).map(|tag| tag.value.trim().parse::<u64>().unwrap_or(0))
}
/// The tags that keep a chat whatever its age: a person pinned or starred it.
const KEPT_TAGS: [&str; 2] = ["pinned", "starred"];

/// Whether a person asked to keep this chat: pinned in their list (`_acpmux/pin`, synced
/// `pin/<id>`), or tagged `pinned` or `starred` with no expiry or one still ahead. A delete pass
/// and an offload pass (`cloud_offload.rs`) never take a kept chat (cmuxterm-hq
/// `docs/design/cold-storage-and-shared-tier.md` section 5: "Pinned and starred chats are never
/// deleted").
pub(crate) fn kept_by_person(meta: &SessionMeta) -> bool {
    let now = now_ms();
    meta.pinned
        || KEPT_TAGS.iter().any(|name| {
            meta.tags.get(*name).is_some_and(|tag| tag.expires_at.is_none_or(|at| at > now))
        })
}

/// How long a chat stays unchanged before a pass deletes it, from the settings document; None
/// when the setting is absent, 0, or not a positive number of days (`7`, `"7"`, `"7d"`).
/// [`AUTO_SETTING`] on reads [`AUTO_DAYS_SETTING`] (180 when absent or not a number of days).
pub(crate) fn delete_after(doc: &Value) -> Option<std::time::Duration> {
    let auto = match crate::user_settings::value(doc, AUTO_SETTING) {
        Some(Value::Bool(on)) => on,
        Some(Value::String(s)) => matches!(s.trim(), "true" | "on"),
        _ => false,
    };
    let days = if auto {
        crate::user_settings::value(doc, AUTO_DAYS_SETTING)
            .and_then(days_of)
            .filter(|days| *days > 0)
            .unwrap_or(AUTO_DAYS_DEFAULT)
    } else {
        days_of(crate::user_settings::value(doc, SETTING)?)?
    };
    (days > 0).then(|| std::time::Duration::from_secs(days.saturating_mul(86_400)))
}

/// A number of days: `7`, `"7"` or `"7d"`.
fn days_of(value: Value) -> Option<u64> {
    match value {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => {
            let s = s.trim();
            s.strip_suffix('d').unwrap_or(s).parse::<u64>().ok()
        }
        _ => None,
    }
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
        if kept_by_person(&meta) {
            return Err("kept");
        }
        match deleted_at(&meta) {
            // Deleted: purged once its undo window passed, and only while still hidden.
            Some(at) => {
                if at > now_ms().saturating_sub(UNDO_MS) {
                    return Err("undo");
                }
                if !meta.tags.contains_key(super::inactive_archive::ARCHIVED_TAG) {
                    return Err("restored");
                }
            }
            None if self.age(session, &meta) > cutoff => return Err("recent"),
            None => {}
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
        if self.archive_held_with(session, cold)
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
    /// mode change take, and its revision is still `seen`: a tombstone, or the purge of one past
    /// its undo window. Whether it was deleted.
    async fn delete_old_chat(
        &self,
        session: &Arc<Session>,
        cutoff: u64,
        hosted: &std::collections::HashSet<String>,
        seen: u64,
        by: &str,
    ) -> Result<bool, RpcError> {
        let Ok(_turn) = session.turn_lock.try_lock() else { return Ok(false) };
        let Ok(using) = session.harness_use.try_write() else { return Ok(false) };
        let Ok(spawning) = session.spawn_lock.try_lock() else { return Ok(false) };
        if self.history_deletable(session, cutoff, hosted) != Ok(seen) {
            return Ok(false);
        }
        drop(spawning);
        if deleted_at(&session.meta()).is_none() {
            self.tombstone(session, by)?;
            return Ok(true);
        }
        self.kill_held(
            session,
            true,
            using.downgrade(),
            crate::close_why::CloseWhy::by("app", "history deleted"),
        )
        .await?;
        Ok(true)
    }

    /// Hides `session` as deleted: archived (unless the person archived it already) and tagged
    /// [`DELETED_TAG`] with now and [`DELETED_BY_TAG`] with `by`, in one tag write.
    fn tombstone(&self, session: &Session, by: &str) -> Result<(), RpcError> {
        use super::inactive_archive::{ARCHIVED_BY_TAG, ARCHIVED_TAG};
        let now = now_ms().to_string();
        let mut set = serde_json::Map::new();
        set.insert(DELETED_TAG.into(), Value::String(now.clone()));
        let by = if by.is_empty() { "cli" } else { by };
        set.insert(DELETED_BY_TAG.into(), Value::String(by.into()));
        if !session.meta().tags.contains_key(ARCHIVED_TAG) {
            set.insert(ARCHIVED_TAG.into(), Value::String(now));
            set.insert(ARCHIVED_BY_TAG.into(), Value::String(ARCHIVED_BY_DELETE.into()));
        }
        self.set_tags_answered(session, Some(&set), &[], None)
    }

    /// The undo (`history-delete --restore ID`): `session` deleted and not purged yet is back in
    /// the lists as it was, with an archive its person made kept. Whether it was deleted.
    pub fn history_restore(&self, session: &Session) -> Result<bool, RpcError> {
        use super::inactive_archive::{ARCHIVED_BY_TAG, ARCHIVED_TAG};
        let meta = session.meta();
        if deleted_at(&meta).is_none() {
            return Ok(false);
        }
        let mut remove = vec![DELETED_TAG.to_owned(), DELETED_BY_TAG.to_owned()];
        if meta.tags.get(ARCHIVED_BY_TAG).is_some_and(|t| t.value == ARCHIVED_BY_DELETE) {
            remove.push(ARCHIVED_TAG.to_owned());
            remove.push(ARCHIVED_BY_TAG.to_owned());
        }
        self.set_tags_answered(session, None, &remove, None)?;
        Ok(true)
    }

    /// Recently deleted (`history-delete --deleted`): every deleted chat not purged yet, newest
    /// delete first, with when it goes for good: `{chats: [{sessionId, name, deletedAt,
    /// deletedBy, purgesAt}]}`.
    pub fn history_deleted(&self) -> Value {
        let mut chats: Vec<(u64, Value)> = self
            .session_handles()
            .into_iter()
            .filter_map(|session| {
                let meta = session.meta();
                let at = deleted_at(&meta)?;
                let by = meta.tags.get(DELETED_BY_TAG).map(|t| t.value.clone());
                Some((
                    at,
                    json!({
                        "sessionId": session.id,
                        "name": meta.title.clone().unwrap_or_else(|| meta.name.clone()),
                        "deletedAt": at,
                        "deletedBy": by,
                        "purgesAt": at.saturating_add(UNDO_MS),
                    }),
                ))
            })
            .collect();
        chats.sort_by_key(|c| std::cmp::Reverse(c.0));
        json!({"undoDays": UNDO_DAYS, "chats": chats.into_iter().map(|(_, row)| row).collect::<Vec<_>>()})
    }

    /// A deleted chat that runs again (a prompt sent to it by id) is no longer deleted: the
    /// pass restores it instead of purging it later.
    fn restore_used(&self, session: &Session) {
        let meta = session.meta();
        let cold = meta.cold.is_some() || self.store.is_cold(&session.id);
        // Deleted while closed, or idle and cold-archived (`history_deletable`): any other status
        // means it ran since.
        let used = match meta.status {
            SessionStatus::Closed => false,
            SessionStatus::Idle => !cold,
            _ => true,
        };
        if used && deleted_at(&meta).is_some() {
            if let Err(e) = self.history_restore(session) {
                tracing::warn!(session = %session.id, "history delete: restore: {}", e.message);
            }
        }
    }

    /// The automatic pass, on the retention worker (`hub/retention.rs`): nothing when the
    /// setting is 0 or absent. With [`EXPORT_SETTING`] set, each chat is exported first.
    pub(super) async fn history_delete_pass(self: &Arc<Self>) {
        let Ok((after, export)) =
            tokio::task::spawn_blocking(|| (delete_after_now(), export_to_now())).await
        else {
            return;
        };
        if let Some(after) = after {
            let req = HistoryDeleteRequest { export, by: "auto", ..Default::default() };
            if let Err(e) = self.history_delete_run(after, req).await {
                tracing::warn!("history delete: {}", e.message);
            }
        }
    }

    /// [`Self::history_delete_pass`] for chats unchanged for longer than `after`, with no
    /// export: how many it deleted.
    #[cfg(test)]
    pub(super) async fn history_delete_pass_after(
        self: &Arc<Self>,
        after: std::time::Duration,
    ) -> u64 {
        let req = HistoryDeleteRequest { by: "auto", ..Default::default() };
        match self.history_delete_run(after, req).await {
            Ok(report) => report.get("deleted").and_then(Value::as_u64).unwrap_or(0),
            Err(e) => {
                tracing::warn!("history delete: {}", e.message);
                0
            }
        }
    }

    /// `_acpmux/history_delete` (`acpmux daemon history-delete`): the chats a pass deletes, by
    /// `olderThanDays` or the setting. A dry run is the preview: it lists them, with their size
    /// and idle days, and deletes nothing.
    pub async fn history_delete_now(
        self: &Arc<Self>,
        req: HistoryDeleteRequest,
    ) -> Result<Value, RpcError> {
        let after = match req.older_than_days {
            Some(0) => None,
            Some(days) => Some(std::time::Duration::from_secs(u64::from(days) * 86_400)),
            None => tokio::task::spawn_blocking(delete_after_now).await.ok().flatten(),
        };
        let Some(after) = after else {
            return Err(RpcError::invalid_params(format!(
                "no age to delete by: pass olderThanDays, or set {SETTING} to a number of days"
            )));
        };
        self.history_delete_run(after, req).await
    }

    /// Every chat unchanged for longer than `after`, oldest first, one at a time, stopping
    /// between two chats at a shutdown: listed (dry run), or exported when asked and then
    /// deleted. A chat whose export fails is kept. The report: `{dryRun, olderThanDays,
    /// deleted|wouldDelete, bytes, chats[], skipped{why: n}, export?}`.
    async fn history_delete_run(
        self: &Arc<Self>,
        after: std::time::Duration,
        req: HistoryDeleteRequest,
    ) -> Result<Value, RpcError> {
        let now = now_ms();
        let cutoff = now.saturating_sub(u64::try_from(after.as_millis()).unwrap_or(u64::MAX));
        // An unreadable host folder could hide a running agent: no pass then.
        if let Err(e) = crate::agent_host::load_records(&crate::agent_host::hosts_dir()) {
            return Err(RpcError::internal(format!("agent host records: {e:#}")));
        }
        let hosted = Self::live_host_sessions();
        let mut sessions = self.session_handles();
        sessions.sort_by_key(|s| s.meta().updated_at);
        let (mut count, mut purged, mut bytes) = (0u64, 0u64, 0u64);
        let mut chats = Vec::new();
        let mut skipped: std::collections::BTreeMap<&'static str, u64> = Default::default();
        for session in sessions {
            if self.shutting_down() {
                break;
            }
            if !req.dry_run {
                self.restore_used(&session);
            }
            if let Err(why) = self.history_deletable(&session, cutoff, &hosted) {
                *skipped.entry(why).or_default() += 1;
                continue;
            }
            let purge = deleted_at(&session.meta()).is_some();
            let dir = self.store.session_path(&session.id);
            let size = match dir.clone() {
                Some(dir) => {
                    tokio::task::spawn_blocking(move || folder_bytes(&dir)).await.unwrap_or(0)
                }
                None => 0,
            };
            // The size read yields: what ran meanwhile (a status write, the end of a cold
            // archive) may have changed the chat, so the revision the delete checks is taken
            // only now, after it.
            let seen = match self.history_deletable(&session, cutoff, &hosted) {
                Ok(seen) => seen,
                Err(why) => {
                    *skipped.entry(why).or_default() += 1;
                    continue;
                }
            };
            let meta = session.meta();
            let mut row = json!({
                "sessionId": session.id,
                "name": meta.name,
                "cwd": meta.cwd,
                "idleDays": now.saturating_sub(self.age(&session, &meta)) / 86_400_000,
                "bytes": size,
                "cold": meta.cold.is_some(),
            });
            if purge && let Some(row) = row.as_object_mut() {
                row.insert("purge".into(), json!(true));
            }
            if req.dry_run {
                if purge {
                    purged += 1;
                } else {
                    count += 1;
                }
                bytes += size;
                if chats.len() < LISTED {
                    chats.push(row);
                }
                continue;
            }
            // Exported when deleted; the purge of the same chat later exports nothing again.
            if let (false, Some(to), Some(dir)) = (purge, req.export.clone(), dir) {
                let id = session.id.clone();
                let exported =
                    tokio::task::spawn_blocking(move || export_chat(&dir, &to.join(&id))).await;
                match exported {
                    Ok(Ok(())) => {}
                    Ok(Err(e)) => {
                        tracing::warn!(session = %session.id, "history delete: export: {e:#}");
                        *skipped.entry("export").or_default() += 1;
                        continue;
                    }
                    Err(_) => {
                        *skipped.entry("export").or_default() += 1;
                        continue;
                    }
                }
            }
            match self.delete_old_chat(&session, cutoff, &hosted, seen, req.by).await {
                Ok(true) => {
                    if purge {
                        purged += 1;
                    } else {
                        count += 1;
                    }
                    bytes += size;
                    if chats.len() < LISTED {
                        if let Some(row) = row.as_object_mut() {
                            row.insert("deleted".into(), json!(true));
                        }
                        chats.push(row);
                    }
                }
                Ok(false) => *skipped.entry("changed").or_default() += 1,
                Err(e) => {
                    tracing::warn!(session = %session.id, "history delete: {}", e.message);
                    *skipped.entry("error").or_default() += 1;
                }
            }
        }
        if count + purged > 0 && !req.dry_run {
            tracing::info!(
                "history delete: {count} chats unchanged for {after:?} deleted, {purged} purged \
                 ({bytes} bytes)"
            );
        }
        let mut report = json!({
            "dryRun": req.dry_run,
            "olderThanDays": after.as_secs() / 86_400,
            "bytes": bytes,
            "chats": chats,
            "skipped": skipped,
            "undoDays": UNDO_DAYS,
        });
        if let Some(fields) = report.as_object_mut() {
            fields.insert(if req.dry_run { "wouldDelete" } else { "deleted" }.into(), json!(count));
            fields.insert(if req.dry_run { "wouldPurge" } else { "purged" }.into(), json!(purged));
            if let Some(to) = &req.export {
                fields.insert("export".into(), json!(to));
            }
        }
        Ok(report)
    }
}

/// The most chats a report lists by name (its counts cover all of them).
const LISTED: usize = 200;

/// What `_acpmux/history_delete` is asked.
#[derive(Debug, Default, Clone)]
pub struct HistoryDeleteRequest {
    /// Only list what would go: the preview.
    pub dry_run: bool,
    /// Instead of the setting; 0 is refused as no age.
    pub older_than_days: Option<u32>,
    /// Copy each chat's folder to `<export>/<chat id>/` before it is deleted.
    pub export: Option<PathBuf>,
    /// Who deletes ([`DELETED_BY_TAG`]): `auto` for the pass; empty is `cli`.
    pub by: &'static str,
}

/// Where the automatic pass exports each chat before it deletes it; none: no export.
pub(crate) const EXPORT_SETTING: &str = "agents.chats.deleteHistoryExportTo";

/// [`EXPORT_SETTING`] of the settings file as it is now, `~/` expanded; only an absolute folder.
fn export_to_now() -> Option<PathBuf> {
    let crate::user_settings::Settings::Parsed(doc) = crate::user_settings::read() else {
        return None;
    };
    let raw = crate::user_settings::value(&doc, EXPORT_SETTING)?;
    let raw = raw.as_str()?.trim();
    let path = match raw.strip_prefix("~/") {
        Some(rest) => dirs::home_dir()?.join(rest),
        None => PathBuf::from(raw),
    };
    path.is_absolute().then_some(path)
}

/// Bytes of the files under `dir`, not following links.
fn folder_bytes(dir: &Path) -> u64 {
    let Ok(entries) = crate::home_fs::read_dir(dir) else { return 0 };
    entries
        .into_iter()
        .map(|entry| {
            let path = dir.join(&entry.name);
            match crate::home_fs::symlink_metadata(&path) {
                Ok(m) if m.is_dir() => folder_bytes(&path),
                Ok(m) if m.is_file() => m.len(),
                _ => 0,
            }
        })
        .sum()
}

/// Copies the chat folder `from` (its metadata, log segments or cold archive, cloud stub) to
/// `to`, which must not exist yet, through a temporary sibling renamed into place, so a crash
/// leaves no half export under the chat's name. Links are not followed or copied.
fn export_chat(from: &Path, to: &Path) -> anyhow::Result<()> {
    if crate::home_fs::try_exists_nofollow(to)? {
        anyhow::bail!("{} exists already", to.display());
    }
    let parent = to.parent().ok_or_else(|| anyhow::anyhow!("no parent folder"))?;
    crate::home_fs::create_dir_all(parent, 0o700)?;
    let name = to.file_name().and_then(|n| n.to_str()).unwrap_or("chat");
    let tmp = parent.join(format!(".{name}.export-{}", std::process::id()));
    if crate::home_fs::try_exists_nofollow(&tmp)? {
        crate::home_fs::remove_dir_all(&tmp)?;
    }
    copy_tree(from, &tmp)?;
    crate::home_fs::sync_dir(&tmp)?;
    crate::home_fs::rename(&tmp, to)?;
    crate::home_fs::sync_dir(parent)?;
    Ok(())
}

fn copy_tree(from: &Path, to: &Path) -> anyhow::Result<()> {
    crate::home_fs::create_dir(to, 0o700)?;
    for entry in crate::home_fs::read_dir(from)? {
        let (src, dst) = (from.join(&entry.name), to.join(&entry.name));
        let meta = crate::home_fs::symlink_metadata(&src)?;
        if meta.is_dir() {
            copy_tree(&src, &dst)?;
        } else if meta.is_file() {
            crate::home_fs::copy(&src, &dst)?;
            std::fs::File::open(&dst)?.sync_all()?;
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "history_delete_tests.rs"]
mod tests;
