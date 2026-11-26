//! Part of `Hub`; see `hub/mod.rs`. Read-only cloud copies of Claude's and Codex's own transcripts.
//!
//! Leo, 2026-11-25: "we also want to be offering up session history offloading and auto
//! deletion i think". `cmux_session_cloud::transcripts` copies `~/.codex/sessions` rollouts and
//! `~/.claude/projects` transcripts to the person's cloud history store, sealed with their key, and
//! never rewrites them. Two settings, both off by default:
//!
//! - `agents.chats.transcriptOffload`: the retention worker (`hub/retention.rs`) copies every
//!   transcript unchanged for `agents.chats.cloudOffloadAfterDays` (default 14).
//! - `agents.chats.transcriptOffloadDeleteLocal`: after a copy was read back and matched the
//!   file's bytes, the local file goes (a `<file>.cloud` stub stays). Never a pinned chat's, nor
//!   a chat with an agent or a client.
//!
//! Both need cloud history set up (`session-cloud.json`); without it nothing leaves the machine.
//! A chat whose transcript went comes back on open ([`Hub::restore_transcripts`], from
//! `ensure_child`, before its agent starts). `_acpmux/transcript_offload {dryRun?, olderThanDays?,
//! restoreAll?}` (`acpmux daemon transcript-offload`) runs one pass now, or undoes every removal.

use super::*;

/// Whether transcripts are copied on their own.
pub(crate) const SETTING_ON: &str = "agents.chats.transcriptOffload";
/// Whether a verified copy's local file is removed.
pub(crate) const SETTING_DELETE: &str = "agents.chats.transcriptOffloadDeleteLocal";
/// After how many days unchanged (shared with the chats' cloud offload).
pub(crate) const SETTING_DAYS: &str = "agents.chats.cloudOffloadAfterDays";
const DEFAULT_DAYS: u64 = 14;
/// The tag that keeps a chat local and whole (as `history_delete.rs`).
const KEPT_TAG: &str = "pinned";

/// What the settings ask: None when the copy is off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Settings {
    pub days: u64,
    pub delete_local: bool,
}

pub(crate) fn settings(doc: &Value) -> Option<Settings> {
    let on = |key| crate::user_settings::value(doc, key) == Some(Value::Bool(true));
    if !on(SETTING_ON) {
        return None;
    }
    let days = crate::user_settings::value(doc, SETTING_DAYS)
        .and_then(|v| v.as_u64())
        .filter(|days| *days > 0)
        .unwrap_or(DEFAULT_DAYS);
    Some(Settings { days, delete_local: on(SETTING_DELETE) })
}

fn settings_now() -> Option<Settings> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => settings(&doc),
        _ => None,
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// What `_acpmux/transcript_offload` is asked.
#[derive(Debug, Default, Clone)]
pub struct TranscriptOffloadRequest {
    /// Only list what would go; needs no cloud.
    pub dry_run: bool,
    /// Instead of the setting's days.
    pub older_than_days: Option<u32>,
    /// Bring every removed transcript back instead (undo).
    pub restore_all: bool,
}

/// Where the transcripts live, and the state folder with the ledger and `session-cloud.json`.
fn folders() -> Option<(std::path::PathBuf, std::path::PathBuf)> {
    Some((dirs::home_dir()?, crate::config::home()))
}

impl Hub {
    /// The agent session ids no pass removes: pinned chats, and any with an agent, a client, a
    /// turn or a queue.
    fn transcript_keep(&self) -> std::collections::HashSet<String> {
        let hosted = Self::live_host_sessions();
        let now = now_ms();
        self.session_handles()
            .into_iter()
            .filter_map(|session| {
                let meta = session.meta();
                let sid = meta.agent_session_id.clone()?;
                let pinned = meta.pinned
                    || meta
                        .tags
                        .get(KEPT_TAG)
                        .is_some_and(|t| t.expires_at.is_none_or(|at| at > now));
                let busy = !session.child.try_lock().is_ok_and(|child| child.is_none())
                    || hosted.contains(&session.id)
                    || session.attached.load(Ordering::SeqCst) > 0
                    || session.turn().is_some()
                    || session.queued() > 0;
                (pinned || busy).then_some(sid)
            })
            .collect()
    }

    /// The automatic pass, on the retention worker: nothing when the setting is off or cloud
    /// history is not set up.
    pub(super) async fn transcript_offload_pass(self: &Arc<Self>) {
        let Ok(Some(settings)) = tokio::task::spawn_blocking(settings_now).await else { return };
        let Some((_, state)) = folders() else { return };
        if !state.join(cmux_session_cloud::config::CONFIG_FILE).exists() {
            return;
        }
        if let Err(e) = self.transcript_offload_run(settings, false).await {
            tracing::warn!("transcript offload: {}", e.message);
        }
    }

    /// `_acpmux/transcript_offload`. By hand, the setting's days and removal, or the defaults (copy
    /// only) when the setting is off.
    pub async fn transcript_offload_now(
        self: &Arc<Self>,
        req: TranscriptOffloadRequest,
    ) -> Result<Value, RpcError> {
        if req.restore_all {
            let (home, state) = folders().ok_or_else(|| RpcError::internal("no home folder"))?;
            let back = tokio::task::spawn_blocking(move || {
                let cloud = cmux_session_cloud::Cloud::get_in(&state)?.ok_or_else(|| {
                    anyhow::anyhow!("cloud history is off: no session-cloud.json")
                })?;
                cmux_session_cloud::transcripts::restore_all(&home, &state, &cloud)
            })
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
            .map_err(|e| RpcError::internal(format!("{e:#}")))?;
            return Ok(json!({"restored": back}));
        }
        let set = tokio::task::spawn_blocking(settings_now).await.ok().flatten();
        let settings = Settings {
            days: req
                .older_than_days
                .map(u64::from)
                .or(set.map(|s| s.days))
                .unwrap_or(DEFAULT_DAYS),
            delete_local: set.is_some_and(|s| s.delete_local),
        };
        self.transcript_offload_run(settings, req.dry_run).await
    }

    async fn transcript_offload_run(
        self: &Arc<Self>,
        settings: Settings,
        dry_run: bool,
    ) -> Result<Value, RpcError> {
        let (home, state) = folders().ok_or_else(|| RpcError::internal("no home folder"))?;
        let policy = cmux_session_cloud::transcripts::Policy {
            older_than_ms: settings.days.saturating_mul(86_400_000),
            delete_local: settings.delete_local,
            keep: self.transcript_keep(),
            now_ms: now_ms(),
        };
        let hub = Arc::downgrade(self);
        let report = tokio::task::spawn_blocking(move || {
            let cloud = cmux_session_cloud::Cloud::get_in(&state)?;
            if cloud.is_none() && !dry_run {
                anyhow::bail!("cloud history is off: no session-cloud.json");
            }
            let stop = || hub.upgrade().is_none_or(|hub| hub.shutting_down());
            cmux_session_cloud::transcripts::pass(
                &home,
                &state,
                cloud.as_deref(),
                &policy,
                dry_run,
                &stop,
            )
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(|e| RpcError::internal(format!("{e:#}")))?;
        serde_json::to_value(report).map_err(|e| RpcError::internal(e.to_string()))
    }

    /// Fetch on open: brings back a chat's transcripts a pass removed, before its agent resumes
    /// from them. One `stat` when no transcript was ever offloaded here. A failure is logged and
    /// the start goes on (the agent then starts as it would with the file gone).
    pub(super) async fn restore_transcripts(&self, session: &Session) {
        let Some(sid) = session.meta().agent_session_id.clone() else { return };
        let Some((home, state)) = folders() else { return };
        let result = tokio::task::spawn_blocking(move || -> anyhow::Result<usize> {
            if !cmux_session_cloud::transcripts::needs_restore(&home, &state, &sid) {
                return Ok(0);
            }
            let cloud = cmux_session_cloud::Cloud::get_in(&state)?
                .ok_or_else(|| anyhow::anyhow!("cloud history is off: no session-cloud.json"))?;
            cmux_session_cloud::transcripts::restore(&home, &state, &cloud, &sid)
        })
        .await;
        match result {
            Ok(Ok(0)) => {}
            Ok(Ok(n)) => {
                tracing::info!("transcripts: {n} file(s) of {} back from the cloud", session.id)
            }
            Ok(Err(e)) => tracing::warn!("transcripts of {}: {e:#}", session.id),
            Err(e) => tracing::warn!("transcripts of {}: {e}", session.id),
        }
    }
}

#[cfg(test)]
#[path = "transcript_offload_tests.rs"]
mod tests;
