//! Part of `Hub`; see `hub/mod.rs`. Moving old cold-archived chats to cloud history on a setting.
//!
//! Leo, 2026-11-25: "we also want to be offering up session history offloading and auto
//! deletion i think". `cmux-session-cloud` and `Store::offload_cold` (cmux#49883) move one
//! cold-archived chat's archive to the person's cloud history store and leave a stub; nothing
//! called them on its own. With `agents.chats.cloudOffload` true (off by default) and cloud history
//! set up, the retention worker (`hub/retention.rs`, after the cold archive pass) offloads every
//! chat that is cold-archived, idle or closed, unchanged for `agents.chats.cloudOffloadAfterDays`
//! (default 14), not pinned, not among the [`KEEP_NEWEST`] newest chats, with no agent or client:
//! the design's policy (cmuxterm-hq `docs/design/cloud-session-history/offload.md` section 2).
//! Each offload is the store's own: it uploads, verifies, and commits the stub under the cold
//! lock, only while the archive still holds the bytes uploaded. A batch with any offload then
//! registers this machine's cloud root once, so the store keeps the blobs. The first read of an
//! offloaded chat fetches it back. `_acpmux/history_offload {dryRun?, olderThanDays?}`
//! (`acpmux daemon history-offload`) runs one pass now.

use super::*;

/// Whether old cold chats are offloaded on their own.
pub(crate) const SETTING_ON: &str = "agents.chats.cloudOffload";
/// After how many days unchanged.
pub(crate) const SETTING_DAYS: &str = "agents.chats.cloudOffloadAfterDays";
const DEFAULT_DAYS: u64 = 14;
/// The newest chats always kept on this disk, whatever their age (a working set after a break).
pub(crate) const KEEP_NEWEST: usize = 20;
/// The tag that keeps a chat local and whole (as `history_delete.rs`).
const KEPT_TAG: &str = "pinned";

/// How long a cold chat stays unchanged before a pass offloads it; None when the setting is off.
pub(crate) fn offload_after(doc: &Value) -> Option<std::time::Duration> {
    if crate::user_settings::value(doc, SETTING_ON) != Some(Value::Bool(true)) {
        return None;
    }
    let days = crate::user_settings::value(doc, SETTING_DAYS)
        .and_then(|v| v.as_u64())
        .filter(|days| *days > 0)
        .unwrap_or(DEFAULT_DAYS);
    Some(std::time::Duration::from_secs(days.saturating_mul(86_400)))
}

fn offload_after_now() -> Option<std::time::Duration> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => offload_after(&doc),
        _ => None,
    }
}

/// What `_acpmux/history_offload` is asked.
#[derive(Debug, Default, Clone)]
pub struct HistoryOffloadRequest {
    /// Only list what would go.
    pub dry_run: bool,
    /// Instead of the setting.
    pub older_than_days: Option<u32>,
}

impl Hub {
    /// Whether a pass may offload `session`, among `newest` (the ids kept local): its
    /// `updated_at`, or why not.
    pub(super) fn offloadable(
        &self,
        session: &Session,
        cutoff: u64,
        newest: &std::collections::HashSet<String>,
        hosted: &std::collections::HashSet<String>,
    ) -> Result<u64, &'static str> {
        let meta = session.meta();
        if meta.cold.is_none() || !self.store.is_cold(&session.id) {
            return Err("not archived");
        }
        if !matches!(meta.status, SessionStatus::Closed | SessionStatus::Idle) {
            return Err("open");
        }
        if meta.tags.get(KEPT_TAG).is_some_and(|tag| tag.expires_at.is_none_or(|at| at > now_ms()))
        {
            return Err("kept");
        }
        if newest.contains(&session.id) {
            return Err("newest");
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
        if session.purging.load(Ordering::SeqCst)
            || session.moving().is_some()
            || session.turn().is_some()
            || session.queued() > 0
            || self.importing.lock().unwrap_or_else(|e| e.into_inner()).contains(&session.id)
        {
            return Err("busy");
        }
        Ok(meta.updated_at)
    }

    /// The automatic pass, on the retention worker: nothing when the setting is off.
    pub(super) async fn history_offload_pass(self: &Arc<Self>) {
        let Ok(Some(after)) = tokio::task::spawn_blocking(offload_after_now).await else { return };
        if let Err(e) = self.history_offload_run(after, false).await {
            tracing::warn!("cloud history offload: {}", e.message);
        }
    }

    /// `_acpmux/history_offload`: by `olderThanDays` or the setting's days (the default's when
    /// the setting is off, so a person can run one by hand).
    pub async fn history_offload_now(
        self: &Arc<Self>,
        req: HistoryOffloadRequest,
    ) -> Result<Value, RpcError> {
        let days = match req.older_than_days {
            Some(days) => u64::from(days),
            None => tokio::task::spawn_blocking(offload_after_now)
                .await
                .ok()
                .flatten()
                .map_or(DEFAULT_DAYS, |after| after.as_secs() / 86_400),
        };
        self.history_offload_run(std::time::Duration::from_secs(days * 86_400), req.dry_run).await
    }

    /// Every offloadable chat, oldest first, one at a time on a blocking thread, stopping between
    /// two chats at a shutdown. The report: `{dryRun, olderThanDays, offloaded|wouldOffload,
    /// bytes, chats[], skipped{why: n}, rootBlobs?}`.
    async fn history_offload_run(
        self: &Arc<Self>,
        after: std::time::Duration,
        dry_run: bool,
    ) -> Result<Value, RpcError> {
        let now = now_ms();
        let cutoff = now.saturating_sub(u64::try_from(after.as_millis()).unwrap_or(u64::MAX));
        if let Err(e) = crate::agent_host::load_records(&crate::agent_host::hosts_dir()) {
            return Err(RpcError::internal(format!("agent host records: {e:#}")));
        }
        let hosted = Self::live_host_sessions();
        let mut sessions = self.session_handles();
        sessions.sort_by_key(|s| std::cmp::Reverse(s.meta().updated_at));
        let newest: std::collections::HashSet<String> =
            sessions.iter().take(KEEP_NEWEST).map(|s| s.id.clone()).collect();
        sessions.reverse();
        let (mut count, mut bytes) = (0u64, 0u64);
        let mut chats = Vec::new();
        let mut skipped: std::collections::BTreeMap<String, u64> = Default::default();
        for session in sessions {
            if self.shutting_down() {
                break;
            }
            let seen = match self.offloadable(&session, cutoff, &newest, &hosted) {
                Ok(seen) => seen,
                Err(why) => {
                    *skipped.entry(why.to_owned()).or_default() += 1;
                    continue;
                }
            };
            let meta = session.meta();
            let row = json!({
                "sessionId": session.id,
                "name": meta.name,
                "idleDays": now.saturating_sub(self.age(&session, &meta)) / 86_400_000,
                "archiveBytes": meta.cold.as_ref().map(|c| c.bytes_after),
            });
            if dry_run {
                count += 1;
                bytes += meta.cold.as_ref().map_or(0, |c| c.bytes_after);
                if chats.len() < 200 {
                    chats.push(row);
                }
                continue;
            }
            // Under the chat's turn lock (no turn starts meanwhile), and only while unchanged.
            let Ok(_turn) = session.turn_lock.try_lock() else {
                *skipped.entry("busy".into()).or_default() += 1;
                continue;
            };
            if self.offloadable(&session, cutoff, &newest, &hosted) != Ok(seen) {
                *skipped.entry("busy".into()).or_default() += 1;
                continue;
            }
            // The store is a borrowed trait object: run its blocking move off the runtime worker.
            match crate::qos::off_worker(|| {
                crate::qos::background(|| self.store.offload_cold(&session.id))
            }) {
                Ok(Some(freed)) => {
                    count += 1;
                    bytes += freed;
                    if chats.len() < 200 {
                        chats.push(row);
                    }
                }
                Ok(None) => *skipped.entry("not offloaded".into()).or_default() += 1,
                Err(e) => {
                    tracing::warn!(session = %session.id, "cloud history offload: {e:#}");
                    *skipped.entry("error".into()).or_default() += 1;
                }
            }
        }
        let mut report = json!({
            "dryRun": dry_run,
            "olderThanDays": after.as_secs() / 86_400,
            "bytes": bytes,
            "chats": chats,
            "skipped": skipped,
        });
        report[if dry_run { "wouldOffload" } else { "offloaded" }] = json!(count);
        if count > 0 && !dry_run {
            tracing::info!("cloud history offload: {count} chats, {bytes} bytes freed");
            match crate::qos::off_worker(|| self.store.register_cloud_root()) {
                Ok(blobs) => report["rootBlobs"] = json!(blobs),
                Err(e) => tracing::warn!("cloud history root: {e:#}"),
            }
        }
        Ok(report)
    }
}

#[cfg(test)]
#[path = "cloud_offload_tests.rs"]
mod tests;
