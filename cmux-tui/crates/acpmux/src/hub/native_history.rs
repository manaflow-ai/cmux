//! `_acpmux/native_history`: a chat's older turns, read from its Claude Code transcript a page at
//! a time (Leo 2026-10-29: "i also like the way it just loads in the subagent stuff instantly :("
//! / "as in i want ours to load fast too :(").
//!
//! Adopting or watching a Claude Code chat seeds its log with the transcript's newest page only
//! (`adoption.rs`, `watch.rs`, `adopt_replay_page.rs`), and a `native_history` record whose
//! `before` is where the next older page ends. A pane that has paged the log back to its first
//! record asks for the page before that cursor, then for the page before the cursor each reply
//! gives, until it is 0. The reply goes to the caller only: no page is ever written to the log.
//!
//! `{sessionId, before}` → `{events, before, turns, read}`. `events` are the page's turns as
//! adopting logs them (`turn_records`), oldest first, each with a `seq` below 1, so they sort before
//! every logged record and never count as one of the log's (`native_seq`). `before` is the next
//! cursor, 0 when nothing older holds a turn. A page reads at most `PAGE_MAX_BYTES` (16 MiB) and
//! a step, paging past pages with no turn up to `SCAN_MAX_BYTES` (`claude_page_with_turns`).
//!
//! Where: the chat's watched transcript, else its Claude session's `<id>.jsonl` in the store its
//! agent runs with, found as `_acpmux/subagent_transcript` finds that store. The caller names only
//! a cursor, never a path.

use super::{Hub, Session};
use crate::adopt_replay::PastTurn;
use crate::rpc::RpcError;
use crate::store::now_ms;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Transcript pages read at once on this daemon: each parses up to 16 MiB of JSON lines.
static READS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

/// A record's place on its page takes the low `KEY_BITS` of its seq; the page's cursor the rest.
/// A page holds at most `PAGE_TURNS` (200) turns of at most `MAX_TOOLS` (400) calls, so at most
/// 200 × 805 records: under 2^18.
const KEY_BITS: u32 = 18;
/// Every native seq is below 1 and at least -2^52, a safe integer in JavaScript.
const SEQ_SPAN: i64 = 1 << 52;
/// The furthest cursor a seq can hold: 16 GiB into a transcript.
pub(super) const MAX_BEFORE: u64 = 1 << (52 - KEY_BITS);

/// The seq of the `k`th record of the page that ends at `before`. The same cursor gives the same
/// seqs every time, so a page read twice merges as one, and every seq of an older page (a smaller
/// `before`) is below every seq of a newer one.
pub(super) fn native_seq(before: u64, k: usize) -> i64 {
    debug_assert!(before < MAX_BEFORE && k < 1 << KEY_BITS);
    (((before as i64) << KEY_BITS) | k as i64) - SEQ_SPAN
}

/// One record of a past turn as a chat's log holds it.
pub(super) struct TurnRecord {
    pub dir: &'static str,
    pub kind: &'static str,
    pub msg: Value,
    /// When it happened (ms since the epoch), when the transcript says.
    pub at: Option<u64>,
    /// `turn_end` and `turn_result` name their turn's `turn_started` seq (`turnSeq`), which the
    /// caller sets once it knows it.
    pub names_turn: bool,
}

/// The records a past turn shows as, oldest first, `turn_started` first: its prompt, its tool
/// calls (each starts running and its update settles it, so the pane folds them under "Worked
/// for"), its answer, and its end. Adopting logs them (`replay_adopted`); an older page sends them.
pub(super) fn turn_records(
    turn: &PastTurn,
    agent_sid: &str,
    turn_id: &str,
    prompt_id: &str,
) -> Vec<TurnRecord> {
    let update = |fields: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": agent_sid, "update": fields}});
    let record = |dir, kind, msg, at| TurnRecord { dir, kind, msg, at, names_turn: false };
    // The turn ends with its answer, or its last tool call when that ended later.
    let started = turn.prompt_at;
    let answered = turn.answer_at.or(started);
    let ended = turn.tools.iter().filter_map(|t| t.ended_at).chain(answered).max();
    let mut out = vec![record(
        "mux",
        "turn_started",
        json!({"prompt": turn.prompt.chars().take(200).collect::<String>(), "client": "adopt", "promptId": prompt_id, "turnId": turn_id, "control": "local"}),
        started,
    )];
    // A page that begins inside a turn has that turn's prompt in the older page.
    if !turn.prompt.is_empty() {
        out.push(record(
            "mux",
            "user_message",
            json!({"text": turn.prompt, "client": "adopt", "promptId": prompt_id, "turnId": turn_id}),
            started,
        ));
    }
    for tool in &turn.tools {
        let start = tool.started_at.or(tool.ended_at).or(started);
        let mut call = tool.call.clone();
        call.set("sessionUpdate", json!("tool_call"));
        call.set("toolCallId", json!(tool.id));
        call.set("status", json!("in_progress"));
        out.push(record("in", "tool_call", update(call), start));
        let mut done = tool.done.clone();
        done.set("sessionUpdate", json!("tool_call_update"));
        done.set("toolCallId", json!(tool.id));
        out.push(record("in", "tool_call_update", update(done), tool.ended_at.or(start)));
    }
    if !turn.answer.is_empty() {
        out.push(record(
            "in",
            "agent_message_chunk",
            update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": turn.answer}})),
            answered,
        ));
    }
    let mut end =
        record("mux", "turn_end", json!({"stopReason": "end_turn", "turnId": turn_id}), ended);
    end.names_turn = true;
    out.push(end);
    // A settled turn: clients and restart recovery read `turn_result`, not `turn_end`.
    let mut result = record(
        "mux",
        "turn_result",
        json!({"status": "completed", "stopReason": "end_turn", "turnId": turn_id, "promptId": prompt_id}),
        ended,
    );
    result.names_turn = true;
    out.push(result);
    out
}

pub(crate) async fn handle(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(params)?)?;
    if session.purged.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(RpcError::invalid_params("no such chat"));
    }
    let before =
        params.get("before").and_then(Value::as_u64).filter(|b| *b > 0).ok_or_else(|| {
            RpcError::invalid_params("before must be a native_history cursor above 0")
        })?;
    if before >= MAX_BEFORE {
        return Err(RpcError::invalid_params("before is past the 16 GiB a cursor can name"));
    }
    let file = transcript(hub, &session)
        .await
        .ok_or_else(|| RpcError::invalid_params("the chat has no Claude Code transcript"))?;
    let _turn = READS.acquire().await.map_err(|e| RpcError::internal(e.to_string()))?;
    let session = session.clone();
    tokio::task::spawn_blocking(move || older_page(&session, &file, before))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))
}

/// The chat's Claude Code transcript: the one it watches, else its Claude session's in its store.
async fn transcript(hub: &Arc<Hub>, session: &Session) -> Option<PathBuf> {
    let meta = session.meta();
    if let Some(watching) = meta.watching.as_ref().filter(|w| w.family == "claude") {
        return Some(watching.file.clone());
    }
    let id = meta.agent_session_id.clone().filter(|id| super::subagent_transcript::plain_id(id))?;
    let home = super::subagent_transcript::claude_home(hub, &meta).await?;
    tokio::task::spawn_blocking(move || crate::adopt::find_claude(&home, &id)).await.ok().flatten()
}

/// The reply for the page of `file` that ends at `before`.
pub(super) fn older_page(session: &Session, file: &Path, before: u64) -> Value {
    let page = crate::adopt_replay::claude_page_with_turns(
        file,
        Some(before),
        crate::adopt_replay::PAGE_TURNS,
    );
    let agent_sid = session.meta().agent_session_id.unwrap_or_default();
    // A record the transcript gives no time takes the one before it, else the page's first.
    let mut at = page.turns.iter().find_map(|t| t.prompt_at.or(t.answer_at)).unwrap_or_else(now_ms);
    let mut events = Vec::new();
    for (i, turn) in page.turns.iter().enumerate() {
        let (turn_id, prompt_id) =
            (format!("native-{before}-{i}"), format!("native-prompt-{before}-{i}"));
        let mut turn_seq = 0;
        for record in turn_records(turn, &agent_sid, &turn_id, &prompt_id) {
            let seq = native_seq(before, events.len());
            let mut msg = record.msg;
            if record.names_turn {
                msg.set("turnSeq", json!(turn_seq));
            }
            if record.kind == "turn_started" {
                turn_seq = seq;
            }
            super::tool_paths::add_canonical_paths(session, record.kind, &mut msg);
            at = record.at.unwrap_or(at);
            events.push(json!({"sessionId": session.id, "seq": seq, "at": at,
                "dir": record.dir, "kind": record.kind, "msg": msg}));
        }
    }
    json!({"events": events, "before": page.start, "turns": page.turns.len(), "read": page.read})
}

#[cfg(test)]
#[path = "native_history_tests.rs"]
mod tests;
