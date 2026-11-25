//! Part of `Hub`; see `hub/mod.rs`. Opt-in team usage sharing (`cmux-usage-share`): while
//! `diagnostics.usageSharing` is on and its notice acknowledged (`diagnostics.usageSharingNoticeAck`), every turn's end spools one
//! `turn` record (its harness, model, wall time, token counts, tool calls, cost, outcome, and the
//! hashed ids of its session, repository and machine), and the daemon uploads the spool to the
//! person's team on cmux-platform (`usage_share_upload.rs`). Off records nothing.
//!
//! Every turn's end passes through [`Hub::record_last_turn`] once; the turn's start and tool
//! calls come from its `TurnInfo` (taken by `finish_turn` into `Session::ending`, or still on
//! `Session::turn` for a turn that ended before its prompt reached the agent).

use super::{Session, TurnInfo};
use cmux_usage_share::TurnFacts;
use cmux_usage_share::record::Outcome;
use serde_json::Value;

/// Spools the turn whose `turn_result` is `msg`, when sharing is on.
pub(super) fn turn_ended(session: &Session, msg: &Value) {
    let Some(sharer) = cmux_usage_share::global() else { return };
    if !sharer.enabled() {
        return;
    }
    let turn_id = msg.get("turnId").and_then(Value::as_str);
    let of_turn = |t: &TurnInfo| Some(t.turn_id.as_str()) == turn_id;
    let turn = session
        .ending
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .filter(|t| of_turn(t))
        .map(|t| (t.started_at, t.doing.tool_calls))
        .or_else(|| {
            session
                .turn
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .filter(|t| of_turn(t))
                .map(|t| (t.started_at, t.doing.tool_calls))
        });
    let (harness, cwd) = {
        let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        (meta.harness.clone(), meta.cwd.clone())
    };
    let facts = facts_of(&session.id, &harness, &cwd, msg, turn, crate::store::now_ms());
    sharer.record_turn(&facts);
}

/// The facts of a `turn_result` record: `turn` is the turn's start (Unix ms) and tool calls.
fn facts_of<'a>(
    session_id: &'a str,
    harness: &'a str,
    cwd: &'a std::path::Path,
    msg: &'a Value,
    turn: Option<(u64, u32)>,
    now: u64,
) -> TurnFacts<'a> {
    let n = |key: &str| msg.get(key).and_then(Value::as_u64).unwrap_or(0);
    TurnFacts {
        session_id,
        harness,
        model: msg.get("model").and_then(Value::as_str),
        cwd: Some(cwd),
        ms: turn.map_or(0, |(started, _)| now.saturating_sub(started)),
        // `inputTokens` is the fresh input alone for every harness this acpmux records
        // (`turn_usage.rs` INPUT_EXCLUDES_CACHE), as the platform's cache hit rate reads it.
        input_tokens: n("inputTokens"),
        output_tokens: n("outputTokens"),
        cache_read_tokens: n("cacheReadTokens"),
        cache_write_tokens: n("cacheWriteTokens"),
        tool_calls: turn.map_or(0, |(_, tools)| tools),
        cost_usd: msg.get("costUsd").and_then(Value::as_f64),
        outcome: msg.get("status").and_then(Value::as_str).and_then(Outcome::from_status),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_turn_result_gives_its_facts() {
        let msg = json!({"status": "completed", "model": "claude-opus-4-5", "inputTokens": 12,
            "outputTokens": 34, "cacheReadTokens": 56, "cacheWriteTokens": 78, "costUsd": 0.5,
            "turnId": "t1", "promptId": "p1"});
        let cwd = std::path::Path::new("/tmp/x");
        let f = facts_of("s1", "claude", cwd, &msg, Some((1_000, 4)), 3_500);
        assert_eq!(f.ms, 2_500);
        assert_eq!(f.tool_calls, 4);
        assert_eq!((f.input_tokens, f.output_tokens), (12, 34));
        assert_eq!((f.cache_read_tokens, f.cache_write_tokens), (56, 78));
        assert_eq!(f.cost_usd, Some(0.5));
        assert_eq!(f.model, Some("claude-opus-4-5"));
        assert_eq!(f.outcome, Some(Outcome::Done));
        for (status, outcome) in [("cancelled", Outcome::Cancelled), ("failed", Outcome::Failed)] {
            let msg = json!({"status": status, "turnId": "t1"});
            let f = facts_of("s1", "codex", cwd, &msg, None, 9);
            assert_eq!(f.outcome, Some(outcome));
            assert_eq!((f.ms, f.tool_calls, f.input_tokens), (0, 0, 0));
        }
    }
}
