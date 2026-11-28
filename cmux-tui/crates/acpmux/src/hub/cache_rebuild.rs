//! What a turn paid to rebuild a prompt cache it should have read (RFD 0167 row 16, "visible
//! cost per task: before, during and after"; cmuxterm-hq
//! docs/research/2026-11-28-cost-10x-cache-rebuilds.md).
//!
//! `turn_cost.rs` says what a turn cost. It does not say how much of that was waste. On our fleet a
//! 95% cache hit rate still left cache writes at 46% of Claude's cost, and the cold rebuilds among
//! them, served as reads, would have cost about 21% less in total (cmuxterm-hq
//! docs/findings/2026-11-22-prompt-cache-hit-rate.md). No agent product shows that number per turn,
//! so a person cannot see that the 40-minute pause, the edited `CLAUDE.md` or the compaction is
//! what made the turn dear.
//!
//! A turn's usage is its model calls added up, so a cold first call is told from the sums: a warm
//! turn writes about what its context grew (`contextTokens` now less the previous turn's), and a
//! cold one writes the previous context again on top of that. So, with the previous turn's context
//! `P`, this turn's writes `W` and its context `C`:
//! - `rebuilt = clamp(W - max(0, C - P), 0, P)`, the tokens written again;
//! - the turn is a rebuild when `P >= MIN_CONTEXT` and `rebuilt >= P / 2`, the per-request rule
//!   of the 2026-11-22 finding;
//! - `cacheRebuildUsd` is `rebuilt` at the turn's write rate (its hour-long share at that tier)
//!   less the cache read rate, what the same tokens would have cost read;
//! - `cacheRebuildCause` is `compaction` when the context shrank below `COMPACTED` of `P`, `idle`
//!   when the gap since the previous turn passed the cache's life (`IDLE_1H_S` for hour-long
//!   writes, which live about 35 min in practice; `IDLE_5M_S` for 5-minute ones), else `prefix`
//!   (the prompt's start changed inside the cache's life: a restart that reloaded an edited
//!   `CLAUDE.md`, a tool list change, a retry moved to another account).
//!
//! The first turn of a chat, a fork's first, and any turn with no `contextTokens` carry nothing:
//! they have no previous context to compare. `sessionCacheRebuildUsd` is the chat's running total.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::Session;

/// A previous context below this is cheap to write again; not worth flagging.
pub const MIN_CONTEXT: u64 = 20_000;
/// A context this share of the previous one or less was compacted.
pub const COMPACTED: f64 = 0.6;
/// Seconds past which an hour-long cache is mostly gone (measured: 69% of requests 35-60 min after
/// the last miss; the 2026-11-22 finding's idle-gap curve).
pub const IDLE_1H_S: u64 = 35 * 60;
/// Seconds past which a 5-minute cache is gone.
pub const IDLE_5M_S: u64 = 5 * 60;

/// What the next turn's rebuild is measured against: the last turn's context and when it ended.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LastTurnCache {
    pub context_tokens: u64,
    pub ended_ms: u64,
}

/// The session's state the rebuild rule reads and writes, kept on `SessionMeta`.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CacheRebuildState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last: Option<LastTurnCache>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_usd: Option<f64>,
}

impl CacheRebuildState {
    /// Nothing kept yet (the meta leaves the field out).
    pub fn is_empty(&self) -> bool {
        self.last.is_none() && self.total_usd.is_none()
    }
}

fn usd(x: f64) -> f64 {
    (x * 1e6).round() / 1e6
}

/// The rebuild fields for a turn whose `turn_result` fields are `fields`, ended at `now_ms`, with
/// the session's state before it `state`. Returns them and the state after it.
pub fn rebuild_fields(
    fields: &Map<String, Value>,
    now_ms: u64,
    state: CacheRebuildState,
) -> (Map<String, Value>, CacheRebuildState) {
    let n = |key: &str| fields.get(key).and_then(Value::as_u64);
    let mut out = Map::new();
    let mut next = state;
    let Some(context) = n("contextTokens") else {
        return (out, next);
    };
    next.last = Some(LastTurnCache { context_tokens: context, ended_ms: now_ms });
    let Some(prev) = state.last else {
        return (out, next);
    };
    let p = prev.context_tokens;
    let written = n("cacheWriteTokens").unwrap_or(0);
    let rebuilt = written.saturating_sub(context.saturating_sub(p)).min(p);
    if p < MIN_CONTEXT || rebuilt < p / 2 {
        return (out, next);
    }
    let written_1h = n("cacheWrite1hTokens").unwrap_or(0).min(written);
    let share_1h = if written == 0 { 0.0 } else { written_1h as f64 / written as f64 };
    let gap_s = now_ms.saturating_sub(prev.ended_ms) / 1000;
    let idle_after = if share_1h > 0.5 { IDLE_1H_S } else { IDLE_5M_S };
    let cause = if (context as f64) < COMPACTED * p as f64 {
        "compaction"
    } else if gap_s >= idle_after {
        "idle"
    } else {
        "prefix"
    };
    out.insert("cacheRebuildTokens".into(), json!(rebuilt));
    out.insert("cacheRebuildCause".into(), json!(cause));
    out.insert("cacheIdleSeconds".into(), json!(gap_s));
    let price = fields
        .get("model")
        .and_then(Value::as_str)
        .and_then(|m| crate::pricing::table().lookup(m))
        .map(|(_, p)| p);
    if let Some(p) = price {
        let write_rate =
            share_1h * p.cache_write_1h_rate() + (1.0 - share_1h) * p.cache_write.unwrap_or(0.0);
        let read_rate = p.cache_read.unwrap_or(p.input);
        let waste = (rebuilt as f64 * (write_rate - read_rate) / 1e6).max(0.0);
        let total = state.total_usd.unwrap_or(0.0) + waste;
        out.insert("cacheRebuildUsd".into(), json!(usd(waste)));
        out.insert("sessionCacheRebuildUsd".into(), json!(usd(total)));
        next.total_usd = Some(total);
    }
    (out, next)
}

/// `rebuild_fields` for `session`'s turn: adds them to `msg` and keeps the state on its meta.
pub(super) fn add_cache_rebuild(session: &Session, msg: &mut Map<String, Value>) {
    let now_ms = crate::store::now_ms();
    let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
    let (fields, next) = rebuild_fields(msg, now_ms, meta.cache_rebuild);
    meta.cache_rebuild = next;
    drop(meta);
    msg.extend(fields);
}

#[cfg(test)]
#[path = "cache_rebuild_tests.rs"]
mod tests;
