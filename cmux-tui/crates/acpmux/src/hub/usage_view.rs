//! The hub's side of `usage_stats.rs`: which chats are read, when, and where the
//! result goes (`SessionSummary.usageStats`).
//!
//! A pass reads every Claude Code and Codex chat that is open or changed in the
//! last day, on one blocking thread, from where the last pass ended. Nothing
//! watches the files and no timer runs: a session list or info read starts a
//! pass at most every [`REFRESH_EVERY_MS`], and a turn's end starts one, one pass
//! at a time; while nobody asks, nothing is read. A pass ends when every chat's
//! new lines are read (at most 64 MiB a file); nothing outlives it but each
//! chat's offsets and minute buckets, and a closed or purged chat's go on the
//! next pass.

use super::{Hub, Session};
use crate::protocol::session::UsageStats;
use crate::store::{SessionMeta, SessionStatus};
use crate::usage_stats::{DAY_MS, Models, Prices, Source, Tracker};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

/// The least time between the starts of two passes a read starts.
const REFRESH_EVERY_MS: u64 = 5_000;
/// How long a session list or info read waits for its pass; past that it
/// answers with the last pass's stats and the pass ends on its own.
pub(crate) const READ_WAIT: Duration = Duration::from_millis(750);

#[derive(Default)]
pub(crate) struct UsageCache {
    trackers: Arc<StdMutex<HashMap<String, Tracker>>>,
    stats: Arc<StdMutex<HashMap<String, UsageStats>>>,
    /// Held for a pass, with when the last one started: a read that comes
    /// meanwhile waits for it instead of reading the stats it is about to replace.
    pass: tokio::sync::Mutex<u64>,
}

impl Hub {
    /// Reads the chats' usage, after the pass that runs if one does, unless one started
    /// in the last few seconds (`force`: a turn ended, so its chat's spend changed).
    pub(crate) async fn refresh_usage_stats(&self, force: bool) {
        let cache = &self.usage_stats;
        let mut last = cache.pass.lock().await;
        let now = crate::store::now_ms();
        if !force && now.saturating_sub(*last) < REFRESH_EVERY_MS {
            return;
        }
        *last = now;
        let mut sources = Vec::new();
        for session in self.sessions() {
            let m = session.meta();
            let family = m.family.clone().unwrap_or_default();
            let Some(sid) = m.agent_session_id.clone().filter(|s| !s.is_empty()) else { continue };
            if !matches!(family.as_str(), "claude" | "codex")
                || m.status == SessionStatus::Closed && m.updated_at + DAY_MS < now
            {
                continue;
            }
            let env = crate::route_account::spawn_env(&m, self.harness_env(&m).await.1);
            let argv = m.spawn_argv.clone().unwrap_or_else(|| m.harness_argv.clone());
            let source = Source {
                family,
                agent_session_id: sid,
                cwd: m.cwd.clone(),
                created_at: m.created_at,
                argv,
                env,
            };
            sources.push((m.id.clone(), source));
        }
        let models = models(&self.catalog.current());
        let (trackers, stats) = (cache.trackers.clone(), cache.stats.clone());
        // A read that stops waiting lets the pass go on; the trackers' lock keeps passes apart.
        let pass = tokio::task::spawn_blocking(move || {
            let mut trackers = trackers.lock().unwrap_or_else(|e| e.into_inner());
            trackers.retain(|id, _| sources.iter().any(|(s, _)| s == id));
            let fresh: HashMap<String, UsageStats> = sources
                .iter()
                .map(|(id, source)| {
                    let tracker = trackers.entry(id.clone()).or_default();
                    (id.clone(), tracker.refresh(source, crate::store::now_ms(), &models))
                })
                .collect();
            *stats.lock().unwrap_or_else(|e| e.into_inner()) = fresh;
        });
        let _ = pass.await;
    }

    /// Starts a pass and leaves it to run (a turn ended: its spend changed).
    pub(super) fn refresh_usage_stats_later(self: &Arc<Self>) {
        let hub = self.clone();
        tokio::spawn(async move { hub.refresh_usage_stats(true).await });
    }

    /// The last pass's stats for a chat, with what the hub itself knows over them:
    /// the window its harness reported, and the background subagents it follows.
    pub(super) fn usage_stats_of(&self, session: &Session, m: &SessionMeta) -> Option<UsageStats> {
        let stats = self.usage_stats.stats.lock().unwrap_or_else(|e| e.into_inner());
        let mut stats = stats.get(&m.id).cloned()?;
        let size = m.usage.as_ref().and_then(|u| u.get("size")).and_then(Value::as_u64);
        if let Some(size) = size.filter(|s| *s > 0) {
            stats.context_window = Some(size);
        }
        // A Codex child runs in its own thread; the hub follows it (`subagents.rs`).
        if let Ok(tree) = session.subagents.try_lock() {
            stats.subagents_live = stats.subagents_live.max(tree.background_running() as u64);
        }
        if matches!(m.status, SessionStatus::Closed | SessionStatus::Disconnected) {
            stats.subagents_live = 0;
        }
        Some(stats)
    }
}

/// The catalog's prices and windows by model id; Anthropic's and OpenAI's own
/// entries first, so a reseller's copy of a model never sets its price.
fn models(catalog: &crate::catalog::schema::Catalog) -> Models {
    let mut models = Models::default();
    let first = |key: &String| !(key.starts_with("anthropic/") || key.starts_with("openai/"));
    let mut keys: Vec<&String> = catalog.models.keys().collect();
    keys.sort_by_key(|k| first(k));
    for key in keys {
        let info = &catalog.models[key];
        let Some((_, id)) = key.split_once('/') else { continue };
        let prices = info.cost.as_ref().and_then(|c| {
            Some(Prices {
                input: c.input?,
                output: c.output?,
                cache_read: c.cache_read.or(c.input)?,
                cache_write: c.cache_write.or(c.input)?,
            })
        });
        models.add(id, prices, info.context_window);
    }
    models
}
