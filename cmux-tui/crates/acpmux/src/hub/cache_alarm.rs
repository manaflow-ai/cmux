//! Part of `Hub`; see `hub/mod.rs`. RFD 0158 §1, the cache-prefix invariant's alarm (Leo,
//! 2026-11-24: "RFD AND FUCKING GOOOOO" on harness magic; 2026-11-25: "we can't be letting
//! important rfds like that take breaks"). A prefix break (tools, model or system prompt changed
//! inside a session) is the main cost event of a long session: the next turn re-reads nothing and
//! writes the whole context again. The daemon never edits the prefix itself, so what it can do is
//! SEE a break: a turn whose cache-read share collapses right after a turn that read mostly from
//! cache, with no declared boundary between them (a gap past the cache's 5-minute life, a context
//! surgery, a fresh session's first turn). Such a collapse is counted on the
//! `turn_result` and logged, so the scorecard and the replay of RFD 0161 can assert zero churn.
//!
//! Off: `agents.harnessMagic.cacheAlarm.enabled` false, or `ACPMUX_HM_CACHEALARM=0`. Counters, per
//! turn: `harnessMagic.cacheAlarm.` `observed` (turns read), `collapses` (undeclared), `declared`
//! (collapses a boundary explains), `unreadTokens` (the context re-written by an undeclared one).
//!
//! A turn's share hides a break its later calls read back, so a Claude chat's translator also
//! counts each main-loop call that missed, by cause (`claude_stdio/prompt_cache.rs`):
//! `callMisses`, `callChurn` (cause `unknown`), `callDeclared`, `callUnreadTokens`, `cause.<c>`.
//! `acpmux scorecard --assert-no-churn` fails when `crate::scorecard::CHURN_COUNTERS` sum above
//! zero: the no-churn assertion RFD 0161's replay runs.

use serde_json::{Map, Value};
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

pub(crate) const FEATURE: &str = "cacheAlarm";
/// Past this long since the previous turn the cache has lapsed on its own (the 5-minute tier).
const LAPSE_MS: u64 = 5 * 60 * 1000;
/// A turn reading at least this share of its context from cache was warm.
const WARM_SHARE: f64 = 0.6;
/// A turn reading at most this share has collapsed.
const COLD_SHARE: f64 = 0.2;
/// Smaller contexts are not worth an alarm.
const MIN_TOKENS: u64 = 20_000;
const MAX_SESSIONS: usize = 4096;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Turn {
    pub read: u64,
    pub write: u64,
    pub input: u64,
    pub at_ms: u64,
    /// A boundary the daemon itself declared for this turn (surgery ran, first turn, model changed).
    pub declared: bool,
}

impl Turn {
    pub(crate) fn total(&self) -> u64 {
        self.read.saturating_add(self.write).saturating_add(self.input)
    }
    pub(crate) fn share(&self) -> f64 {
        match self.total() {
            0 => 0.0,
            t => self.read as f64 / t as f64,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// Nothing to say: no baseline, a small context, or a warm turn.
    Quiet,
    /// The share collapsed and a boundary explains it.
    Declared,
    /// The share collapsed with no boundary: a prefix churn. Carries the tokens written again.
    Collapse(u64),
}

/// Judges `now` against the turn before it in the same session.
pub(crate) fn judge(prev: Option<&Turn>, now: &Turn) -> Verdict {
    let Some(prev) = prev else { return Verdict::Quiet };
    if now.total() < MIN_TOKENS || prev.share() < WARM_SHARE || now.share() > COLD_SHARE {
        return Verdict::Quiet;
    }
    if now.declared || now.at_ms.saturating_sub(prev.at_ms) > LAPSE_MS {
        return Verdict::Declared;
    }
    Verdict::Collapse(now.write.saturating_add(now.input))
}

static LAST: LazyLock<Mutex<HashMap<String, Turn>>> = LazyLock::new(Mutex::default);

fn num(o: &Map<String, Value>, k: &str) -> u64 {
    o.get(k).and_then(Value::as_u64).unwrap_or(0)
}

/// Reads a `turn_result`'s usage fields, judges the turn against the session's last, and writes
/// the counters. A turn with no cache fields (a harness that does not report them) is skipped.
pub(crate) fn observe(session: &str, msg: &mut Value, now_ms: u64, on: bool) {
    if !on {
        // The harness's per-call counts (`claude_stdio/prompt_cache.rs`) go with the switch too.
        if let Some(hm) = msg.get_mut("harnessMagic").and_then(Value::as_object_mut) {
            hm.remove(FEATURE);
            if hm.is_empty() {
                msg.as_object_mut().map(|o| o.remove("harnessMagic"));
            }
        }
        return;
    }
    let Some(o) = msg.as_object() else { return };
    if !o.contains_key("cacheReadTokens") && !o.contains_key("cacheWriteTokens") {
        return;
    }
    let surgery = o.keys().any(|k| k.starts_with("harnessMagic.surgery.runs"))
        || o.get("harnessMagic").and_then(|h| h.pointer("/surgery/runs")).is_some();
    let now = Turn {
        read: num(o, "cacheReadTokens"),
        write: num(o, "cacheWriteTokens"),
        input: num(o, "inputTokens"),
        at_ms: now_ms,
        declared: surgery || o.get("turnCount").and_then(Value::as_u64) == Some(1),
    };
    let verdict = {
        let mut map = LAST.lock().unwrap_or_else(|e| e.into_inner());
        if map.len() >= MAX_SESSIONS && !map.contains_key(session) {
            map.clear();
        }
        let prev = map.insert(session.to_owned(), now);
        judge(prev.as_ref(), &now)
    };
    super::harness_magic::add_counter(msg, FEATURE, "observed", 1);
    match verdict {
        Verdict::Quiet => {}
        Verdict::Declared => super::harness_magic::add_counter(msg, FEATURE, "declared", 1),
        Verdict::Collapse(unread) => {
            super::harness_magic::add_counter(msg, FEATURE, "collapses", 1);
            super::harness_magic::add_counter(msg, FEATURE, "unreadTokens", unread);
            eprintln!(
                "acpmux: cache alarm: session {session} read {:.0}% of its context from cache right after a warm turn, with no boundary (a prefix churn)",
                now.share() * 100.0
            );
        }
    }
}

/// Forgets `session`'s baseline (its session ended).
#[allow(dead_code)]
pub(crate) fn forget(session: &str) {
    LAST.lock().unwrap_or_else(|e| e.into_inner()).remove(session);
}

impl super::Hub {
    /// Judges a settled turn's cache reads (`write_turn_result`).
    pub(super) fn cache_alarm(&self, session: &super::Session, msg: &mut Value) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64);
        observe(&session.id, msg, now, super::harness_magic::enabled(FEATURE));
    }
}

#[cfg(test)]
#[path = "cache_alarm_tests.rs"]
mod tests;
