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
//! `{sessionId, before, mark}` → `{events, before, mark, turns, read}`. `events` are the page's turns as
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
use crate::rpc::{MAX_MESSAGE_BYTES, RpcError};
use crate::store::now_ms;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::Arc;

/// The `initialize` feature of a daemon that serves `_acpmux/native_history`; a peer that does
/// not list it is never sent one (`peer_forward.rs`).
pub const FEATURE: &str = "nativeHistory";

/// Transcript pages read at once on this daemon: each parses up to 16 MiB of JSON lines.
static READS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

/// Leave the same one MiB envelope room as ordinary event pages. Native history is a JSON-RPC
/// reply (and may cross a peer that adds metadata), so its result must stay below the transport
/// limit before the request id and wrappers are added.
const REPLY_BYTES: usize = MAX_MESSAGE_BYTES - (1 << 20);

/// A record's place on its page takes the low `KEY_BITS` of its seq; the page's cursor the rest.
/// A page holds at most `PAGE_TURNS` (200) turns of at most `MAX_TOOLS` (400) calls, so at most
/// 200 × 805 records: under 2^18.
const KEY_BITS: u32 = 18;
/// Every native seq is below 1 and at least -2^52, a safe integer in JavaScript.
const SEQ_SPAN: i64 = 1 << 52;
/// The furthest cursor a seq can hold: 16 GiB into a transcript.
pub(super) const MAX_BEFORE: u64 = 1 << (52 - KEY_BITS);

/// Bytes around a native cursor that identify the transcript version. The mark includes the
/// file's stable identity where the platform supplies one, plus a full SHA-256 of the bytes
/// immediately before the cursor. Appending to a transcript preserves this boundary; truncating,
/// rotating, or replacing it makes the cursor stale without hashing a whole (possibly huge) file.
const MARK_BYTES: u64 = 4096;

fn file_identity(meta: &std::fs::Metadata) -> (u64, u64) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (meta.dev(), meta.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        (0, 0)
    }
}

fn digest(file: &mut std::fs::File, at: u64, n: u64) -> Option<String> {
    file.seek(SeekFrom::Start(at)).ok()?;
    let mut bytes = vec![0; usize::try_from(n).ok()?];
    file.read_exact(&mut bytes).ok()?;
    Some(format!("{:x}", Sha256::digest(bytes)))
}

/// A cursor mark is `v1:<dev>:<ino>:<len>:<n>:<sha256>`, where `n` bytes immediately before `before`
/// were hashed. The empty mark is impossible for a usable cursor (`before > 0`).
pub(crate) fn mark(input: &mut std::fs::File, before: u64) -> Option<String> {
    let meta = input.metadata().ok()?;
    if before == 0 || before > meta.len() {
        return None;
    }
    let n = before.min(MARK_BYTES);
    let hash = digest(input, before - n, n)?;
    let (dev, ino) = file_identity(&meta);
    Some(format!("v1:{dev}:{ino}:{}:{n}:{hash}", meta.len()))
}

/// Validates a cursor against the same transcript identity and boundary bytes. A growing file is
/// valid; a shorter, replaced, or rewritten boundary is rejected.
fn mark_holds(input: &mut std::fs::File, before: u64, mark: &str) -> bool {
    let meta = match input.metadata() {
        Ok(meta) => meta,
        Err(_) => return false,
    };
    let mut fields = mark.split(':');
    if fields.next() != Some("v1") {
        return false;
    }
    let (Ok(dev), Ok(ino), Ok(len), Ok(n)) = (
        fields.next().unwrap_or_default().parse::<u64>(),
        fields.next().unwrap_or_default().parse::<u64>(),
        fields.next().unwrap_or_default().parse::<u64>(),
        fields.next().unwrap_or_default().parse::<u64>(),
    ) else {
        return false;
    };
    let Some(hash) = fields.next().filter(|hash| !hash.is_empty()) else { return false };
    let (current_dev, current_ino) = file_identity(&meta);
    if (dev, ino) != (current_dev, current_ino)
        || len < before
        || meta.len() < len
        || fields.next().is_some()
        || n == 0
        || n > MARK_BYTES
        || n > before
        || before > meta.len()
    {
        return false;
    }
    digest(input, before - n, n).is_some_and(|actual| actual == hash)
}

fn stale() -> RpcError {
    RpcError::invalid_params("the transcript changed since this history cursor was read")
        .with_data(json!({"reason": "transcriptRead.stale"}))
}

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
    // Before cursor marks shipped, the daemon persisted only `{before}`. Upgrade only an exact
    // cursor emitted by this chat's own native_history seed; an arbitrary unmarked number remains
    // refused. Legacy cursors cannot prove file identity, so the boundary is marked now and the
    // normal bounded validation applies to subsequent pages.
    let mark = match params.get("mark") {
        Some(Value::String(mark)) if !mark.is_empty() => Some(mark.clone()),
        Some(Value::Null) | None => None,
        Some(_) => return Err(stale()),
    };
    let file = transcript(hub, &session)
        .await
        .ok_or_else(|| RpcError::invalid_params("the chat has no Claude Code transcript"))?;
    let _turn = READS.acquire().await.map_err(|e| RpcError::internal(e.to_string()))?;
    let session = session.clone();
    let hub = hub.clone();
    tokio::task::spawn_blocking(move || {
        let mut input = std::fs::File::open(&file).map_err(|_| stale())?;
        let mark = match mark {
            Some(mark) => mark,
            None => {
                let mut issued = false;
                hub.store
                    .scan_kinds(&session.id, &["native_history"], &mut |event| {
                        if event.dir == "mux"
                            && event.msg.get("before").and_then(Value::as_u64) == Some(before)
                            && event.msg.get("mark").is_none_or(Value::is_null)
                        {
                            issued = true;
                            false
                        } else {
                            true
                        }
                    })
                    .map_err(|_| stale())?;
                if !issued {
                    return Err(stale());
                }
                self::mark(&mut input, before).ok_or_else(stale)?
            }
        };
        if !mark_holds(&mut input, before, &mark) {
            return Err(stale());
        }
        // Keep whole turns whenever possible. A transcript's raw page is bounded, but JSON
        // escaping and ACP event envelopes can expand it past the one-frame RPC limit. Re-read
        // from the same byte cursor with fewer turns until the serialized result fits. The cursor
        // returned by each smaller page is its own start, so no turn is skipped.
        let mut want = crate::adopt_replay::PAGE_TURNS;
        let mut reread = 0u64;
        let reply = loop {
            let page =
                crate::adopt_replay::claude_page_with_turns_open(&mut input, Some(before), want);
            let page_read = page.read;
            let turn_count = page.turns.len();
            // The page and its marks use one descriptor. Recheck after reading for an in-place
            // truncate/rewrite; appends are fine, as are rotations while this descriptor is held.
            if !mark_holds(&mut input, before, &mark) {
                return Err(stale());
            }
            let next_mark = if page.start > 0 { self::mark(&mut input, page.start) } else { None };
            let mut reply = page_reply(&session, before, page, next_mark);
            if result_bytes(&reply) <= REPLY_BYTES || turn_count <= 1 {
                if reread > 0 {
                    let read = reply["read"].as_u64().unwrap_or(0).saturating_add(reread);
                    reply["read"] = json!(read);
                }
                break fit_reply(reply);
            }
            reread = reread.saturating_add(page_read);
            want = turn_count.div_ceil(2);
        };
        Ok(reply)
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?
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

fn page_reply(
    session: &Session,
    before: u64,
    page: crate::adopt_replay::ClaudePage,
    mark: Option<String>,
) -> Value {
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
    json!({"events": events, "before": page.start, "mark": mark, "turns": page.turns.len(), "read": page.read})
}

/// The serialized result size, before the request id and JSON-RPC envelope. The one MiB margin in
/// [`REPLY_BYTES`] is deliberately larger than those wrappers and peer annotations.
fn result_bytes(reply: &Value) -> usize {
    serde_json::to_string(reply).map_or(usize::MAX, |text| text.len())
}

/// Omit the largest event payloads only when one whole turn still cannot fit after page sizing.
/// Every event, including its sequence, kind, timestamps and identity, remains in the page; only
/// its renderable message is replaced by the same explicit marker used by ordinary event pages
/// (`paging::fit_reply`). This makes a large turn finite and advances its byte cursor instead of
/// returning `message.too_large` forever.
fn fit_reply(mut reply: Value) -> Value {
    super::fit_reply(&mut reply);
    reply
}

#[cfg(test)]
#[path = "native_history_tests.rs"]
mod tests;
