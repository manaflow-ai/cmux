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
//!
//! Per call: the sums count a turn's cold calls once, so a turn with several (a long tool call or
//! a 40-minute wait inside it) undercounts; on one fleet host the turn rule found 18.8% of Claude
//! spend where each request's own usage said 32.9%. Claude's stream names each main-loop call's
//! usage at its `message_start`, so its translator applies the same rule to every call, `P` the
//! context the call before left (`CallRebuilds`, `claude_stdio/prompt_cache.rs`), with the cause
//! told per call (a compaction since, the gap since the call before past the cache's life, else
//! the prefix), and sends the turn's sum as `_meta.claude.cacheRebuild`; `turn_usage` carries it
//! here as `callCacheRebuild`, which is not kept. The turn takes the larger of the two counts: a
//! call count misses a cold first call after acpmux restarted (no call before it to compare), and
//! the turn rule still sees that one. A harness that names no per-call usage (Codex) keeps the
//! turn rule alone.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

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

/// The `turn_result` field a Claude turn's per-call count rides in to `rebuild_fields` (not kept).
pub const CALLS_FIELD: &str = "callCacheRebuild";

/// The tokens a call or turn wrote again that it could have read: the context before it was
/// `previous`, it ended (or sent) `context`, and it wrote `written`. None when it was warm, or the
/// context is too small to flag.
pub fn rebuilt(previous: u64, context: u64, written: u64) -> Option<u64> {
    let r = written.saturating_sub(context.saturating_sub(previous)).min(previous);
    (previous >= MIN_CONTEXT && r >= previous / 2).then_some(r)
}

/// One turn's main-loop calls that wrote again a context they could have read (module docs).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CallRebuilds {
    pub tokens: u64,
    /// The hour-long share of `tokens`, by each call's own tier split.
    pub tokens_1h: u64,
    pub by_cause: BTreeMap<&'static str, u64>,
    /// The longest gap before a call that rebuilt for `idle`.
    pub idle_ms: u64,
}

impl CallRebuilds {
    /// A main-loop call found `previous` tokens left by the call before, `gap_ms` after it
    /// started, and sent a prompt of `prompt` tokens, of which it wrote `written` (`written_1h`
    /// of them hour-long), with `compacted` a compaction since.
    pub fn call(
        &mut self,
        previous: u64,
        prompt: u64,
        (written, written_1h): (u64, u64),
        gap_ms: u64,
        compacted: bool,
    ) {
        let Some(r) = rebuilt(previous, prompt, written) else { return };
        let hour = written_1h.min(written).saturating_mul(2) > written;
        let idle_after_ms = 1000 * if hour { IDLE_1H_S } else { IDLE_5M_S };
        let cause = if compacted {
            "compaction"
        } else if gap_ms >= idle_after_ms {
            self.idle_ms = self.idle_ms.max(gap_ms);
            "idle"
        } else {
            "prefix"
        };
        let r_1h = (r as u128 * written_1h.min(written) as u128)
            .checked_div(written as u128)
            .unwrap_or(0) as u64;
        self.tokens = self.tokens.saturating_add(r);
        self.tokens_1h = self.tokens_1h.saturating_add(r_1h);
        *self.by_cause.entry(cause).or_default() += r;
    }

    /// The turn's `_meta.claude.cacheRebuild`: its tokens, their hour-long share, the cause with
    /// the most tokens, and the longest idle gap in seconds.
    pub fn to_json(&self) -> Value {
        let cause = self.by_cause.iter().max_by_key(|(_, n)| **n).map(|(c, _)| *c);
        json!({"tokens": self.tokens, "tokens1h": self.tokens_1h, "cause": cause,
               "idleSeconds": self.idle_ms / 1000})
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
    let written = n("cacheWriteTokens").unwrap_or(0);
    let written_1h = n("cacheWrite1hTokens").unwrap_or(0).min(written);
    // The turn rule: (tokens, hour-long share, cause, idle seconds).
    let by_turn = state.last.and_then(|prev| {
        let p = prev.context_tokens;
        let rebuilt = rebuilt(p, context, written)?;
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
        Some((rebuilt, share_1h, cause.to_owned(), gap_s))
    });
    // The per-call count, when the harness named each call's usage.
    let by_call = fields.get(CALLS_FIELD).and_then(|c| {
        let tokens = c.get("tokens").and_then(Value::as_u64).filter(|t| *t > 0)?;
        let t_1h = c.get("tokens1h").and_then(Value::as_u64).unwrap_or(0).min(tokens);
        let cause = c.get("cause").and_then(Value::as_str).unwrap_or("prefix").to_owned();
        let idle_s = c.get("idleSeconds").and_then(Value::as_u64).unwrap_or(0);
        Some((tokens, t_1h as f64 / tokens as f64, cause, idle_s))
    });
    let best = match (by_turn, by_call) {
        (Some(t), Some(c)) => Some(if c.0 >= t.0 { c } else { t }),
        (t, c) => t.or(c),
    };
    let Some((rebuilt, share_1h, cause, gap_s)) = best else {
        return (out, next);
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
    msg.remove(CALLS_FIELD);
    meta.cache_rebuild = next;
    drop(meta);
    msg.extend(fields);
}

#[cfg(test)]
#[path = "cache_rebuild_tests.rs"]
mod tests;
