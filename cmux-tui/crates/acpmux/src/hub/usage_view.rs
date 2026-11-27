//! The hub's side of `usage_stats.rs`: which chats are read, when, and where the
//! result goes (`SessionSummary.usageStats`).
//!
//! A pass reads every Claude Code and Codex chat that is open or changed in the
//! last day, on one blocking thread, from where the last pass ended. It finds them among the
//! live chats and the kept list order's rows of the last day (`list_order.rs`), never by a walk
//! of every chat: a god daemon's 110,000 closed chats cost a first pass 161 ms. No timer runs:
//! a session list that asks for usage (`usage: true`: `acpmux ls --wide`, `--json`, Session
//! Info's usage read) or an info read starts a pass at most every [`REFRESH_EVERY_MS`] (sooner
//! when a turn ended or a transcript changed since), and a turn's end reads its own chat only;
//! one pass at a time. A plain list reads nothing, and its rows carry what the last pass found.
//!
//! What a pass found is kept in a tag cache (`cmux-tag-cache`, hq#13932), keyed by the chat and
//! tagged with it ([`UsageTag::Chat`], invalidated by its turn's end) and its harness transcript
//! ([`UsageTag::Transcript`], invalidated by the chat index's file watch when it sees the file
//! change). A read serves what is cached, fresh or stale, at once, and the pass that brings it up
//! to date runs behind it (stale-while-revalidate, one at a time): only a read before any whole
//! pass finished waits for one, at most [`READ_WAIT`]. A pass ends when every chat's new lines
//! are read (at most 64 MiB a file); nothing outlives it but each chat's offsets, minute buckets
//! and stats, and a closed or purged chat's go on the next pass.

use super::{Hub, Session};
use crate::protocol::session::UsageStats;
use crate::store::{SessionMeta, SessionStatus};
use crate::usage_stats::{DAY_MS, HOUR_MS, Models, Source, Tracker};
use cmux_chat_index::{AdapterKind, ChatChange, ChatKey};
use cmux_tag_cache::{Stamp, TagCache};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

/// The mux record of a chat's usage after one of its turns (`read_usage`).
pub const RECORD_KIND: &str = "usage_stats";
/// The least time between the starts of two passes a read starts.
const REFRESH_EVERY_MS: u64 = 5_000;
/// How long a read before any whole pass finished waits for one; past that it answers with
/// what is cached and the pass ends on its own.
const READ_WAIT: Duration = Duration::from_millis(750);
/// How many chats' stats are kept: a pass reads the live chats and those of the last day.
const USAGE_ENTRIES: usize = 16_384;

/// What a chat's stats were read from: an invalidation of either leaves them stale.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) enum UsageTag {
    /// The acpmux chat, by id: its turn ended.
    Chat(String),
    /// Its harness's transcript, by the chat index's key: the file watch saw it change.
    Transcript(ChatKey),
}

/// Each chat's last stats, in the tag cache, and the ids written (the cache has no walk; a
/// whole pass's prune walks these).
pub(crate) struct UsageStatsCache {
    cache: TagCache<String, UsageStats, UsageTag>,
    keys: HashSet<String>,
}

impl Default for UsageStatsCache {
    fn default() -> Self {
        Self { cache: TagCache::new(USAGE_ENTRIES), keys: HashSet::new() }
    }
}

impl UsageStatsCache {
    /// The chat's stats, fresh or stale: a read draws what is cached.
    pub(crate) fn get(&self, id: &str) -> Option<&UsageStats> {
        self.cache.get(id).value()
    }

    /// The chat's stats only while no tag of theirs was invalidated since they were read.
    #[cfg(test)]
    pub(crate) fn fresh(&self, id: &str) -> Option<&UsageStats> {
        self.cache.get(id).fresh()
    }

    pub(crate) fn invalidate(&mut self, tag: UsageTag) {
        self.cache.invalidate(tag);
    }

    /// Writes `stats` for `id` as of `read`, a stamp taken before they were read.
    fn insert_at(&mut self, id: String, stats: UsageStats, tags: Vec<UsageTag>, read: Stamp) {
        self.keys.insert(id.clone());
        self.cache.insert_at(id, stats, tags, read);
    }

    /// Drops `id`'s stats; whether any were kept.
    fn remove(&mut self, id: &str) -> bool {
        self.keys.remove(id);
        self.cache.remove(id).is_some()
    }

    #[cfg(test)]
    pub(crate) fn insert_for_test(&mut self, id: &str, stats: UsageStats) {
        let tags = vec![UsageTag::Chat(id.to_owned())];
        let now = self.cache.stamp();
        self.insert_at(id.to_owned(), stats, tags, now);
    }
}

/// The chat index's key of a source's transcript: what its file watch names.
fn transcript_key(source: &Source) -> Option<ChatKey> {
    let harness = match source.family.as_str() {
        "claude" => AdapterKind::ClaudeCode,
        "codex" => AdapterKind::Codex,
        _ => return None,
    };
    Some(ChatKey { harness, session_id: source.agent_session_id.clone() })
}

pub(crate) struct UsageCache {
    trackers: Arc<StdMutex<HashMap<String, Tracker>>>,
    pub(crate) stats: Arc<StdMutex<UsageStatsCache>>,
    /// Held for a pass, with when the last one started: a read that comes
    /// meanwhile waits for it instead of reading the stats it is about to replace.
    pass: tokio::sync::Mutex<u64>,
    /// A turn ended or a transcript changed since the last pass began: the next read reads,
    /// however soon.
    dirty: AtomicBool,
    /// A whole pass finished: a read serves the cache from then on, and never waits.
    warm: Arc<AtomicBool>,
    /// A pass started behind a read is queued or running: another read starts none.
    behind: AtomicBool,
    /// The catalog's prices and windows, built once per catalog in use: every turn's end reads
    /// its chat's usage, and rebuilding them from the whole catalog each time was 8.5% of a
    /// host's CPU in a 2,000-chat prompt burst (coord-sim fan-in ramp, 2026-11-25).
    models: StdMutex<Option<(Arc<crate::catalog::Catalog>, Arc<Models>)>>,
    /// How many whole passes ran, and how many chats the last one read: a gate's timed pass is
    /// one that ran, over the sources it says.
    #[cfg(test)]
    passes: std::sync::atomic::AtomicU64,
    #[cfg(test)]
    sources_read: std::sync::atomic::AtomicUsize,
    /// How long each pass's read takes on top of its own (a slow reader's stub).
    #[cfg(test)]
    read_delay_ms: std::sync::atomic::AtomicU64,
}

impl Default for UsageCache {
    fn default() -> Self {
        Self {
            trackers: Arc::default(),
            stats: Arc::new(StdMutex::new(UsageStatsCache::default())),
            pass: tokio::sync::Mutex::new(0),
            dirty: AtomicBool::new(false),
            warm: Arc::new(AtomicBool::new(false)),
            behind: AtomicBool::new(false),
            models: StdMutex::new(None),
            #[cfg(test)]
            passes: Default::default(),
            #[cfg(test)]
            sources_read: Default::default(),
            #[cfg(test)]
            read_delay_ms: Default::default(),
        }
    }
}

impl UsageCache {
    fn stats(&self) -> std::sync::MutexGuard<'_, UsageStatsCache> {
        self.stats.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// Drops the trackers and stats ids of chats not in `sources` (a whole pass's chats): closed a
/// day ago or purged. A chat still listed keeps what the last pass found until a pass finds more.
/// Returns the chats whose stats went. A set of the listed ids: one lookup per chat, where a
/// walk of every source per chat cost N x N (~9 million compares with 3,000 chats).
/// The harness whose transcripts a chat of `family` writes: Claude Code's for `claude` and a
/// profile named for a Claude Code wrapper (`claude-sr2`, `claude-sr2-pipe` declare
/// `family = "claude-sr2"` and run Claude Code, which writes its own transcript), Codex's for
/// `codex` and a profile named for a Codex wrapper (`codex-review-box` declares
/// `family = "codex-review-box"` and runs Codex in a box); None for any other family, whose
/// usage nothing here reads. Before this, a `claude-sr2` chat had no `usageStats`, so its
/// machine read as unmetered, and so did a `codex-review-box` reviewer's.
pub(super) fn transcript_family(family: &str) -> Option<&'static str> {
    match family {
        f if f == "codex" || f.starts_with("codex-") || f.starts_with("codex_") => Some("codex"),
        f if f == "claude" || f.starts_with("claude-") || f.starts_with("claude_") => {
            Some("claude")
        }
        _ => None,
    }
}

/// A profile env var naming a folder that holds one Codex home per chat: the chat's rollouts
/// are under `<folder>/<chat id>/sessions/`, so its Codex home is `<folder>/<chat id>`.
/// leo-workspace's codex-review-box sets it: its reviewer runs Codex in a box whose own home is
/// RAM, and the box binds only `<folder>/<chat id>/sessions` of the host's, read and write, so
/// one reviewer sees its own transcripts and nothing else of the host's.
pub(crate) const CODEX_HOMES_PER_CHAT: &str = "ACPMUX_CODEX_HOMES_PER_CHAT";

/// Points a Codex chat's read at its own home when its profile keeps one per chat
/// ([`CODEX_HOMES_PER_CHAT`]): `CODEX_HOME` becomes `<folder>/<chat id>`. A chat id that is
/// not one plain path component leaves the env as it was.
pub(super) fn per_chat_codex_home(env: &mut BTreeMap<String, String>, chat_id: &str) {
    let Some(root) = env.get(CODEX_HOMES_PER_CHAT).filter(|r| !r.is_empty()) else { return };
    let plain = !chat_id.is_empty()
        && chat_id != "."
        && chat_id != ".."
        && !chat_id.contains(['/', '\\', '\0']);
    if plain {
        let home = std::path::Path::new(root).join(chat_id).display().to_string();
        env.insert("CODEX_HOME".to_owned(), home);
    }
}

pub(super) fn prune_unlisted<T>(
    trackers: &mut HashMap<String, T>,
    stats: &HashSet<String>,
    sources: &[(String, Source)],
) -> Vec<String> {
    let listed: HashSet<&str> = sources.iter().map(|(s, _)| s.as_str()).collect();
    trackers.retain(|id, _| listed.contains(id.as_str()));
    stats.iter().filter(|id| !listed.contains(id.as_str())).cloned().collect()
}

impl Hub {
    /// The usage read of a session list or row read that asks for usage (`usage: true`, Session
    /// Info's usage read): what is cached is served at once, and a pass, when one is due, runs
    /// behind it. Only a read before any whole pass finished waits for its pass, at most
    /// [`READ_WAIT`].
    pub(crate) async fn read_usage_for_list(self: &Arc<Self>) {
        if !self.usage_stats.warm.load(Ordering::SeqCst) {
            // The pass runs as its own task, and the read waits on its handle: a read that
            // stops waiting drops only the handle. Dropping the pass itself at the wait left
            // its blocking read writing stats with no row told after it, so a closed row
            // cached meanwhile kept no `usageStats` for good (`read_usage`).
            let hub = self.clone();
            let pass = self
                .scope
                .spawn_named("usage-first-pass", async move { hub.refresh_usage_stats().await });
            let _ = tokio::time::timeout(READ_WAIT, pass).await;
            return;
        }
        self.revalidate_usage();
    }

    /// Starts a pass behind the read, unless one is queued or running: it runs only when due
    /// ([`Self::refresh_usage_stats`]).
    pub(crate) fn revalidate_usage(self: &Arc<Self>) {
        if self.usage_stats.behind.swap(true, Ordering::SeqCst) {
            return;
        }
        let hub = self.clone();
        self.scope.spawn_named("usage-revalidate", async move {
            hub.refresh_usage_stats().await;
            hub.usage_stats.behind.store(false, Ordering::SeqCst);
        });
    }

    /// Follows the chat index's changes (`chats/watch.rs`, its file watch): a Claude Code or
    /// Codex transcript that changed leaves its chat's stats stale, and the next read starts a
    /// pass however soon. Ends with the index.
    pub(crate) fn watch_usage_transcripts(self: &Arc<Self>, service: &crate::chats::ChatService) {
        let mut changes = service.subscribe();
        let hub = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("usage-transcripts", async move {
            loop {
                let batch = changes.recv().await;
                let Some(hub) = hub.upgrade() else { return };
                match batch {
                    Ok(batch) => hub.usage_transcripts_changed(batch.iter().map(|c| &c.change)),
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                        hub.usage_stats.dirty.store(true, Ordering::SeqCst);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                }
            }
        });
    }

    /// Invalidates the transcript tag of each changed Claude Code or Codex chat: one write each.
    pub(crate) fn usage_transcripts_changed<'a>(
        &self,
        changes: impl Iterator<Item = &'a ChatChange>,
    ) {
        let mut any = false;
        let mut stats = self.usage_stats.stats();
        for change in changes {
            let key = match change {
                ChatChange::Upsert { chat } => chat.entry.key(),
                ChatChange::Removed { key } => key.clone(),
            };
            if matches!(key.harness, AdapterKind::ClaudeCode | AdapterKind::Codex) {
                stats.invalidate(UsageTag::Transcript(key));
                any = true;
            }
        }
        drop(stats);
        if any {
            self.usage_stats.dirty.store(true, Ordering::SeqCst);
        }
    }

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
        self.read_usage(self.usage_candidates(now), true).await;
    }

    /// The chats a whole pass may read: the live ones, and those the kept list order
    /// (`list_order.rs`) places as changed in the last day, once each. Every chat the pass reads
    /// is one of them (an open chat, or a closed one whose `updatedAt` is inside the day), and
    /// the order has every chat's `updatedAt` as it is now: each write of it is told before the
    /// order's next read. Costs the live chats, the rows changed since the order's last read
    /// and those of the last day, never a walk of every chat.
    fn usage_candidates(&self, now: u64) -> Vec<Arc<Session>> {
        let mut candidates = self.live_session_handles();
        let live: HashSet<&str> = candidates.iter().map(|s| s.id.as_str()).collect();
        // A recent row that is live is already a candidate: one lookup, no id copied.
        let recent: Vec<Arc<Session>> = self
            .own_rows_since(now.saturating_sub(DAY_MS))
            .into_iter()
            .filter(|s| !live.contains(s.id.as_str()))
            .collect();
        drop(live);
        candidates.extend(recent);
        candidates
    }

    /// Whether a whole pass reads `m`'s chat: a Claude Code or Codex chat with its agent's
    /// session id, open or changed in the last day.
    fn reads_usage(m: &SessionMeta, now: u64) -> bool {
        m.agent_session_id.as_deref().is_some_and(|s| !s.is_empty())
            && transcript_family(m.family.as_deref().unwrap_or_default()).is_some()
            && !(m.status == SessionStatus::Closed && m.updated_at.saturating_add(DAY_MS) < now)
    }

    /// The sources of the chats of `sessions` a pass reads ([`Self::reads_usage`], tested on
    /// each chat's metadata in place); only those are copied.
    async fn usage_sources(&self, sessions: &[Arc<Session>], now: u64) -> Vec<(String, Source)> {
        let mut sources = Vec::new();
        for session in sessions {
            if !session.read_meta(|m| Self::reads_usage(m, now)) {
                continue;
            }
            let m = session.meta();
            // Tested above on the same chat: a write since may have taken it out.
            if !Self::reads_usage(&m, now) {
                continue;
            }
            let family = transcript_family(m.family.as_deref().unwrap_or_default())
                .unwrap_or_default()
                .to_owned();
            let sid = m.agent_session_id.clone().unwrap_or_default();
            let (claude_stdio, env) = self.harness_env(&m).await;
            let mut env = crate::route_account::spawn_env(&m, env);
            if family == "codex" {
                per_chat_codex_home(&mut env, &m.id);
            }
            // Only an argv this daemon started it with says how it runs: a watched chat runs in
            // another app, and one never started here (adopted, revived) ran with unknown flags.
            let argv = m.spawn_argv.clone().filter(|_| m.watching.is_none());
            let mut source = Source {
                family,
                agent_session_id: sid,
                cwd: m.cwd.clone(),
                created_at: m.created_at,
                argv,
                env,
            };
            // The window acpmux started it with when the person set none and the settings name
            // one (`harness_limits::lift_claude`).
            if claude_stdio
                && let Some((key, value)) = crate::harness_limits::claude_autocompact_window()
                && crate::usage_stats::claude_autocompact_unset(&source)
            {
                source.env.insert(key.into(), value);
            }
            sources.push((m.id.clone(), source));
        }
        sources
    }

    /// Reads one chat's usage and leaves it to run: its turn ended, so its spend changed. The
    /// next list that asks for usage reads too, however soon, so it never misses this turn.
    /// [`Models`] of the catalog in use, rebuilt only when the catalog is replaced (a new
    /// catalog is a new `Arc`; the one held here keeps its address from being reused).
    fn usage_models(&self) -> Arc<Models> {
        let catalog = self.catalog.current();
        let mut held = self.usage_stats.models.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((of, models)) = held.as_ref()
            && Arc::ptr_eq(of, &catalog)
        {
            return models.clone();
        }
        let models = Arc::new(Models::from_catalog(&catalog));
        *held = Some((catalog, models.clone()));
        models
    }

    pub(crate) fn refresh_usage_stats_of(self: &Arc<Self>, session: &Arc<Session>) {
        // Its stats are stale until this read writes them: one write, whatever is cached.
        self.usage_stats.stats().invalidate(UsageTag::Chat(session.id.clone()));
        self.usage_stats.dirty.store(true, Ordering::SeqCst);
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            let _pass = hub.usage_stats.pass.lock().await;
            hub.read_usage(vec![session], false).await;
        });
    }

    /// Reads `sessions`' records on a blocking thread; `whole`: they are every chat a pass may
    /// read ([`Self::usage_candidates`]), so a chat not read (closed a day ago, purged) loses
    /// its tracker and stats. When any chat's stats changed (but for `updatedAt`) the next
    /// session list is built anew; a turn's own read (not `whole`) records its chat's as a mux
    /// `usage_stats` record, which watchers hear as `_acpmux/session_changed`.
    async fn read_usage(&self, sessions: Vec<Arc<Session>>, whole: bool) {
        let now = crate::store::now_ms();
        let sources = self.usage_sources(&sessions, now).await;
        #[cfg(test)]
        if whole {
            self.usage_stats.sources_read.store(sources.len(), Ordering::SeqCst);
            self.usage_stats.passes.fetch_add(1, Ordering::SeqCst);
        }
        // Only a turn's own read keeps its chat's handle, to announce it; a whole pass resolves
        // what changed in the session map, so it builds no map of its candidates.
        let own = if whole { Vec::new() } else { sessions };
        let models = self.usage_models();
        let cache = &self.usage_stats;
        let (trackers, stats) = (cache.trackers.clone(), cache.stats.clone());
        // A read that stops waiting lets the pass go on; the trackers' lock keeps passes apart.
        #[cfg(test)]
        let delay = Duration::from_millis(cache.read_delay_ms.load(Ordering::SeqCst));
        let warm = cache.warm.clone();
        let pass = tokio::task::spawn_blocking(move || {
            let mut trackers = trackers.lock().unwrap_or_else(|e| e.into_inner());
            // Taken before the files are read: a turn's end or a transcript change meanwhile
            // leaves what this read writes stale (`TagCache::insert_at`).
            let read_at = stats.lock().unwrap_or_else(|e| e.into_inner()).cache.stamp();
            #[cfg(test)]
            std::thread::sleep(delay);
            let mut fresh = Vec::with_capacity(sources.len());
            for (id, source) in &sources {
                let tracker = trackers.entry(id.clone()).or_default();
                if let Some(found) = tracker.refresh(source, crate::store::now_ms(), &models) {
                    let mut tags = vec![UsageTag::Chat(id.clone())];
                    tags.extend(transcript_key(source).map(UsageTag::Transcript));
                    fresh.push((id.clone(), found, tags));
                }
            }
            let mut stats = stats.lock().unwrap_or_else(|e| e.into_inner());
            let same = |a: &UsageStats, b: &UsageStats| {
                a.updated_at / HOUR_MS == b.updated_at / HOUR_MS
                    && UsageStats { updated_at: 0, ..a.clone() }
                        == UsageStats { updated_at: 0, ..b.clone() }
            };
            let changed: Vec<String> = fresh
                .iter()
                .filter(|(id, new, _)| stats.get(id).is_none_or(|old| !same(old, new)))
                .map(|(id, _, _)| id.clone())
                .collect();
            let mut gone = Vec::new();
            if whole {
                gone = prune_unlisted(&mut *trackers, &stats.keys, &sources);
                gone.retain(|id| stats.remove(id));
            }
            // A turn's own read announces its chat's whether or not a list's pass read the
            // turn first, so every turn's end is followed by its usage.
            let announce: Vec<(String, UsageStats)> = if whole {
                Vec::new()
            } else {
                fresh.iter().map(|(id, found, _)| (id.clone(), found.clone())).collect()
            };
            for (id, found, tags) in fresh {
                stats.insert_at(id, found, tags, read_at);
            }
            if whole {
                warm.store(true, Ordering::SeqCst);
            }
            let changed: Vec<String> = changed.into_iter().chain(gone).collect();
            (changed, announce)
        });
        let Ok((changed, announce)) = pass.await else { return };
        // Only the chats whose stats changed or went: their rows, not every closed row. Each is
        // found in the session map (one lookup a chat): a chat pruned for age is there and tells
        // its own row; only a purged one, in no map, makes every closed row stale.
        for id in &changed {
            match self.session_by_id(id) {
                Some(session) => self.events.row_changed(&session),
                None => self.events.all_rows_stale(),
            }
        }
        for (id, stats) in announce {
            if let Some(session) = own.iter().find(|s| s.id == id) {
                let stats = serde_json::to_value(stats).unwrap_or_default();
                self.append(session, "mux", RECORD_KIND, stats);
            }
        }
    }

    /// The last pass's stats for a chat, with what the hub itself knows over them:
    /// the window its harness reported, and the background subagents it follows.
    pub(super) fn usage_stats_of(&self, session: &Session, m: &SessionMeta) -> Option<UsageStats> {
        // Fresh or stale: a stale entry is drawn at once while the pass behind the read reads it.
        let mut stats = self.usage_stats.stats().get(&m.id).cloned()?;
        let size = m.usage.as_ref().and_then(|u| u.get("size")).and_then(Value::as_u64);
        if let Some(size) = size.filter(|s| *s > 0) {
            stats.context_window = Some(size);
        }
        // The background subagents the hub follows (`subagents.rs`): a Codex child, which its
        // rollout does not name, and a Claude one its transcript has not shown yet.
        let followed = session.subagents.try_lock().ok().map(|t| t.background_running() as u64);
        let family = transcript_family(m.family.as_deref().unwrap_or_default());
        stats.subagents_live = match (family, stats.subagents_live, followed) {
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

#[cfg(test)]
impl Hub {
    /// The next read runs a pass however soon, as after a turn's end.
    pub(crate) fn usage_pass_due_for_test(&self) {
        self.usage_stats.dirty.store(true, Ordering::SeqCst);
    }

    /// The candidates both ways, each timed in µs: as #43807 deduped them (a set of every
    /// candidate's id, each id copied) and as now (a set of the live ids); and how many.
    pub(crate) fn usage_candidates_both_for_test(&self) -> (u128, u128, usize) {
        let now = crate::store::now_ms();
        let at = std::time::Instant::now();
        let mut seen = HashSet::new();
        let mut copied = Vec::new();
        let recent = self.own_rows_since(now.saturating_sub(DAY_MS));
        for session in self.live_session_handles().into_iter().chain(recent) {
            if seen.insert(session.id.clone()) {
                copied.push(session);
            }
        }
        let copied_us = at.elapsed().as_micros();
        let at = std::time::Instant::now();
        let candidates = self.usage_candidates(now);
        let live_us = at.elapsed().as_micros();
        assert_eq!(copied.len(), candidates.len(), "the same candidates both ways");
        (copied_us, live_us, candidates.len())
    }

    /// Each pass's read takes `ms` longer from now on.
    pub(crate) fn slow_usage_reads_for_test(&self, ms: u64) {
        self.usage_stats.read_delay_ms.store(ms, Ordering::SeqCst);
    }

    /// How many whole passes ran, and how many chats the last one read.
    pub(crate) fn usage_passes_for_test(&self) -> (u64, usize) {
        let cache = &self.usage_stats;
        (cache.passes.load(Ordering::SeqCst), cache.sources_read.load(Ordering::SeqCst))
    }
}

#[cfg(test)]
#[path = "usage_view_tests.rs"]
mod tests;

#[cfg(test)]
impl Hub {
    /// Sets `id`'s stats as a pass that found them does: kept, and its row told changed.
    pub(crate) fn set_usage_stats_for_test(&self, id: &str, stats: UsageStats) {
        self.usage_stats.stats.lock().unwrap_or_else(|e| e.into_inner()).insert_for_test(id, stats);
        if let Some(session) = self.session_by_id(id) {
            self.events.row_changed(&session);
        }
    }
}
