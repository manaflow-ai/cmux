//! The hub's side of `usage_stats.rs`: which chats are read, when, and where the
//! result goes (`SessionSummary.usageStats`).
//!
//! A pass reads every Claude Code and Codex chat that is open or changed in the
//! last day, on one blocking thread, from where the last pass ended. Nothing
//! watches the files and no timer runs: a session list that asks for usage
//! (`usage: true`: `acpmux ls --wide`, `--json`) or an info read starts a pass at
//! most every [`REFRESH_EVERY_MS`] (sooner when a turn ended since), and a turn's
//! end reads its own chat only; one pass at a time. A plain list reads nothing,
//! and its rows carry what the last pass found. Only the list waits for its pass,
//! at most [`READ_WAIT`]. A pass ends when every chat's
//! new lines are read (at most 64 MiB a file); nothing outlives it but each
//! chat's offsets and minute buckets, and a closed or purged chat's go on the
//! next pass.

use super::{Hub, Session};
use crate::protocol::session::UsageStats;
use crate::store::{SessionMeta, SessionStatus};
use crate::usage_stats::{DAY_MS, Models, Source, Tracker};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

/// The mux record of a chat's usage after one of its turns (`read_usage`).
pub const RECORD_KIND: &str = "usage_stats";
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
    /// A turn ended since the last pass began: the next read reads, however soon.
    dirty: AtomicBool,
}

impl Hub {
    /// Reads every chat's usage, after the pass that runs if one does, unless one started in
    /// the last few seconds and no turn ended since.
    pub(crate) async fn refresh_usage_stats(&self) {
        let mut last = self.usage_stats.pass.lock().await;
        let now = crate::store::now_ms();
        let dirty = self.usage_stats.dirty.swap(false, Ordering::SeqCst);
        if !dirty && now.saturating_sub(*last) < REFRESH_EVERY_MS {
            return;
        }
        *last = now;
        self.read_usage(self.sessions(), true).await;
    }

    /// Reads one chat's usage and leaves it to run: its turn ended, so its spend changed. The
    /// next list that asks for usage reads too, however soon, so it never misses this turn.
    pub(crate) fn refresh_usage_stats_of(self: &Arc<Self>, session: &Arc<Session>) {
        self.usage_stats.dirty.store(true, Ordering::SeqCst);
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            let _pass = hub.usage_stats.pass.lock().await;
            hub.read_usage(vec![session], false).await;
        });
    }

    /// Reads `sessions`' records on a blocking thread; `whole`: they are every chat, so a
    /// chat not among them (closed a day ago, purged) loses its tracker and stats. When any
    /// chat's stats changed (but for `updatedAt`) the next session list is built anew; a
    /// turn's own read (not `whole`) records its chat's as a mux `usage_stats` record, which
    /// watchers hear as `_acpmux/session_changed`.
    async fn read_usage(&self, sessions: Vec<Arc<Session>>, whole: bool) {
        let now = crate::store::now_ms();
        let by_id: HashMap<String, Arc<Session>> =
            sessions.iter().map(|s| (s.id.clone(), s.clone())).collect();
        let mut sources = Vec::new();
        for session in sessions {
            let m = session.meta();
            let family = m.family.clone().unwrap_or_default();
            let Some(sid) = m.agent_session_id.clone().filter(|s| !s.is_empty()) else { continue };
            if !matches!(family.as_str(), "claude" | "codex")
                || m.status == SessionStatus::Closed && m.updated_at.saturating_add(DAY_MS) < now
            {
                continue;
            }
            let env = crate::route_account::spawn_env(&m, self.harness_env(&m).await.1);
            // Only an argv this daemon started it with says how it runs: a watched chat runs in
            // another app, and one never started here (adopted, revived) ran with unknown flags.
            let argv = m.spawn_argv.clone().filter(|_| m.watching.is_none());
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
        let models = Models::from_catalog(&self.catalog.current());
        let cache = &self.usage_stats;
        let (trackers, stats) = (cache.trackers.clone(), cache.stats.clone());
        // A read that stops waiting lets the pass go on; the trackers' lock keeps passes apart.
        let pass = tokio::task::spawn_blocking(move || {
            let mut trackers = trackers.lock().unwrap_or_else(|e| e.into_inner());
            let mut fresh = Vec::with_capacity(sources.len());
            for (id, source) in &sources {
                let tracker = trackers.entry(id.clone()).or_default();
                if let Some(found) = tracker.refresh(source, crate::store::now_ms(), &models) {
                    fresh.push((id.clone(), found));
                }
            }
            let mut stats = stats.lock().unwrap_or_else(|e| e.into_inner());
            let same = |a: &UsageStats, b: &UsageStats| {
                UsageStats { updated_at: 0, ..a.clone() }
                    == UsageStats { updated_at: 0, ..b.clone() }
            };
            let changed: Vec<(String, UsageStats)> = fresh
                .iter()
                .filter(|(id, new)| stats.get(id).is_none_or(|old| !same(old, new)))
                .cloned()
                .collect();
            let mut gone = false;
            if whole {
                trackers.retain(|id, _| sources.iter().any(|(s, _)| s == id));
                let before = stats.len();
                // A chat still listed keeps what the last pass found until a pass finds more.
                stats.retain(|id, _| sources.iter().any(|(s, _)| s == id));
                gone = stats.len() != before;
            }
            // A turn's own read announces its chat's whether or not a list's pass read the
            // turn first, so every turn's end is followed by its usage.
            let announce = if whole { Vec::new() } else { fresh.clone() };
            stats.extend(fresh);
            (changed.is_empty() && !gone, announce)
        });
        let Ok((same, announce)) = pass.await else { return };
        if !same {
            self.events.changed();
        }
        for (id, stats) in announce {
            if let Some(session) = by_id.get(&id) {
                let stats = serde_json::to_value(stats).unwrap_or_default();
                self.append(session, "mux", RECORD_KIND, stats);
            }
        }
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
        // The background subagents the hub follows (`subagents.rs`): a Codex child, which its
        // rollout does not name, and a Claude one its transcript has not shown yet.
        let followed = session.subagents.try_lock().ok().map(|t| t.background_running() as u64);
        stats.subagents_live = match (m.family.as_deref(), stats.subagents_live, followed) {
            (_, Some(read), Some(followed)) => Some(read.max(followed)),
            (Some("codex"), None, followed) => followed,
            (_, read, _) => read,
        };
        // No harness process runs, so none of its subagents does.
        if matches!(
            m.status,
            SessionStatus::Closed | SessionStatus::Disconnected | SessionStatus::Idle
        ) {
            stats.subagents_live = Some(0);
        }
        Some(stats)
    }
}
