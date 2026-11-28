//! What a purged chat spent, kept after it goes: one line per purge in
//! `<home>/spend-of-purged.jsonl` (part of `hub/usage_view.rs`).
//!
//! Why (2026-11-28): an ephemeral run (`acpmux run --ephemeral`, `acpmux exec`) is purged as its
//! reply ends, and a purge takes the chat's row, its tracker and its cost-ledger buckets with it
//! (`hub/ledger`). Whatever it spent was then in no count: `acpmux ls --all` no longer lists it,
//! so leo-workspace `tools/usage_now.py` (HQ NOW's `token_efficiency`) neither metered it nor
//! counted it unmetered. A machine's condition-trigger service starts one such run per decision
//! (a Haiku call every five minutes per rule), and none of them was ever seen.
//!
//! The line is counts, not content: the chat's id, name, harness, model, tags, folder, when it
//! was made and purged, and its tokens and cache reads by model in each UTC hour of its last day
//! (`usage_stats::Tracker::hours`), read to the transcript's end first. `knownSince` says from
//! when those counts are whole: an hour that starts before it is lower than the truth, and `hours`
//! is null when nothing could be read (no transcript found, or the usage pass did not free up
//! within [`PASS_WAIT`]). Lines older than [`KEEP_MS`] go when the file passes
//! [`COMPACT_BYTES`], so it stays small whatever the purge rate.

use super::*;
use std::io::Write;

/// The file's name, beside `sessions/` and `usage-trackers/`.
pub(crate) const FILE: &str = "spend-of-purged.jsonl";
/// Each line's `schema`.
pub(crate) const SCHEMA: &str = "acpmux.spend-of-purged.v1";
/// How long a line is kept: a reader of a completed hour needs at most the last two.
pub(crate) const KEEP_MS: u64 = 2 * DAY_MS;
/// Past this size an append first drops the lines older than [`KEEP_MS`].
pub(crate) const COMPACT_BYTES: u64 = 1 << 20;
/// The most a purge waits for a usage pass under way: past it the line says `hours: null`.
const PASS_WAIT: Duration = Duration::from_secs(5);

impl Hub {
    /// Reads `session`'s usage to its end and appends what it spent to [`FILE`]. Never fails the
    /// purge: a write that fails is logged, and a chat with no saved trackers (a memory store)
    /// writes nothing.
    pub(crate) async fn keep_purged_spend(&self, session: &Arc<Session>) {
        let Some(home) = self.usage_stats.saved.as_deref().and_then(Path::parent) else { return };
        let path = home.join(FILE);
        let m = session.meta();
        let read = match tokio::time::timeout(PASS_WAIT, self.usage_stats.pass.lock()).await {
            Ok(pass) => {
                let now = crate::store::now_ms();
                let sources = self.usage_sources(std::slice::from_ref(session), now).await;
                let models = self.usage_models();
                let (trackers, saved) =
                    (self.usage_stats.trackers.clone(), self.usage_stats.saved.clone());
                let id = session.id.clone();
                let read = tokio::task::spawn_blocking(move || {
                    let (_, source) = sources.into_iter().next()?;
                    read_spend(&trackers, saved.as_deref(), &id, &source, &models, now)
                })
                .await
                .ok()
                .flatten();
                drop(pass);
                read
            }
            Err(_) => None,
        };
        let line = record(&m, crate::store::now_ms(), read.as_ref());
        let wrote = tokio::task::spawn_blocking(move || append(&path, &line)).await;
        match wrote {
            Ok(Ok(())) => {}
            Ok(Err(e)) => tracing::warn!(session = %session.id, "keeping a purged chat's spend failed: {e}"),
            Err(e) => tracing::warn!(session = %session.id, "keeping a purged chat's spend failed: {e}"),
        }
    }
}

/// What a chat spent, as its tracker read it to the end.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Spend {
    pub hours: BTreeMap<u64, (BTreeMap<String, u64>, BTreeMap<String, u64>)>,
    pub known_since: Option<u64>,
    pub model: Option<String>,
}

/// `id`'s tracker (this daemon's, else the one saved in `saved`) read on to the end of `source`.
/// A no-model chat spent nothing, known from its start. None when nothing could be read.
pub(crate) fn read_spend(
    trackers: &StdMutex<HashMap<String, Tracker>>,
    saved: Option<&Path>,
    id: &str,
    source: &Source,
    models: &Models,
    now: u64,
) -> Option<Spend> {
    if source.family == NO_MODEL_FAMILY {
        return Some(Spend { hours: BTreeMap::new(), known_since: Some(0), model: None });
    }
    let mut trackers = trackers.lock().unwrap_or_else(|e| e.into_inner());
    let path = saved.and_then(|dir| saved_path(dir, id));
    let tracker = trackers
        .entry(id.to_owned())
        .or_insert_with(|| path.as_deref().and_then(Tracker::load).unwrap_or_default());
    tracker.refresh(source, now, models)?;
    Some(Spend {
        hours: tracker.hours(),
        known_since: tracker.known_since(),
        model: tracker.model().map(str::to_owned),
    })
}

/// One line of [`FILE`] for chat `m`, purged at `now`.
pub(crate) fn record(m: &SessionMeta, now: u64, spend: Option<&Spend>) -> Value {
    let tags: serde_json::Map<String, Value> =
        m.tags.iter().map(|(k, t)| (k.clone(), Value::String(t.value.clone()))).collect();
    let hours = spend.map(|s| {
        s.hours
            .iter()
            .map(|(start, (tokens, cache_reads))| {
                let hour = serde_json::json!({
                    "tokensByModel": tokens,
                    "cacheReadByModel": cache_reads,
                });
                (start.to_string(), hour)
            })
            .collect::<serde_json::Map<String, Value>>()
    });
    serde_json::json!({
        "schema": SCHEMA,
        "sessionId": m.id,
        "agentSessionId": m.agent_session_id,
        "name": m.name,
        "harness": m.harness,
        "family": m.family,
        "model": spend.and_then(|s| s.model.clone()),
        "tags": tags,
        "cwd": m.cwd,
        "createdAt": m.created_at,
        "purgedAt": now,
        "knownSince": spend.and_then(|s| s.known_since),
        "hours": hours,
    })
}

/// Appends `line` to `path`, first dropping the lines older than [`KEEP_MS`] when the file
/// passed [`COMPACT_BYTES`] (rewritten whole, then renamed over it).
pub(crate) fn append(path: &Path, line: &Value) -> std::io::Result<()> {
    let now = line.get("purgedAt").and_then(Value::as_u64).unwrap_or_else(crate::store::now_ms);
    if std::fs::metadata(path).is_ok_and(|m| m.len() > COMPACT_BYTES) {
        let text = std::fs::read_to_string(path)?;
        let kept: String = text
            .lines()
            .filter(|l| {
                serde_json::from_str::<Value>(l)
                    .ok()
                    .and_then(|v| v.get("purgedAt").and_then(Value::as_u64))
                    .is_some_and(|at| at.saturating_add(KEEP_MS) > now)
            })
            .flat_map(|l| [l, "\n"])
            .collect();
        let tmp = path.with_extension("jsonl.tmp");
        std::fs::write(&tmp, kept)?;
        std::fs::rename(&tmp, path)?;
    }
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(f, "{line}")
}

#[cfg(test)]
#[path = "purged_spend_tests.rs"]
mod tests;
