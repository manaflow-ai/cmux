//! Part of `Hub`; see `hub/mod.rs`. Watches the agent's `session/update`
//! stream for harness signals that a client cannot interpret on its own:
//! an abandoned partial message that the harness redelivers, and error text
//! a failed turn streamed as an ordinary message.

use super::*;

/// Largest trailing message text kept for the error comparison.
const TRAILING_LIMIT: usize = 64 * 1024;

/// Updates that neither end nor continue the message that is streaming.
const NEUTRAL_UPDATES: &[&str] = &[
    "usage_update",
    "available_commands_update",
    "current_mode_update",
    "config_option_update",
    "session_info_update",
    "agent_thought_chunk",
    // A background shell's end is a note beside the message (cx-ncc.84).
    "background_task_update",
    // A compaction is a note between messages; its summary is not shown.
    "compaction",
    "compaction_summary",
    // A subagent's spawn and end belong to the subagent (`crate::subagents`).
    "subagent_spawned",
    "subagent_state_update",
    // A predicted next prompt comes after the turn's answer (`claude_stdio/prompt_suggestions.rs`).
    "prompt_suggestion",
];

/// Codex (`codex-acp`) reports stream trouble as
/// `session_info_update._meta.codex.error`. `willRetry: true` means the
/// harness drops the partial answer and streams it again under a new
/// messageId; `willRetry: false` is a terminal error for the turn.
fn codex_error(update: &Value) -> Option<(bool, Value)> {
    let err = update.pointer("/_meta/codex/error")?;
    if !err.is_object() {
        return None;
    }
    let will_retry = err.get("willRetry").and_then(Value::as_bool).unwrap_or(false);
    Some((will_retry, err.clone()))
}

/// This daemon run's mark in every reply segment id (`reply_segment`): segment numbers start
/// again after a restart, and an id minted before it must never name a reply minted after.
fn segment_boot() -> &'static str {
    static BOOT: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    BOOT.get_or_init(|| {
        let ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis());
        format!("{ms:x}")
    })
}

/// Stamps `segment` on a reply chunk's record, as `_meta.acpmux.segment` beside the agent's own
/// `_meta` (a client reads it with the record's `msg.params`).
pub(super) fn stamp_reply_segment(value: &mut Value, segment: &str) {
    if let Some(params) = value.get_mut("params") {
        super::merge_mux_meta(params, json!({ "segment": segment }));
    }
}

impl Hub {
    /// Ends the reply segment streaming now (`reply_segment`): a prompt (a steer) came between.
    pub(super) fn end_reply_segment(&self, session: &Session) {
        session.stream.lock().unwrap_or_else(|e| e.into_inner()).reply_segment = None;
    }

    /// Called for a live agent `session/update` before it is recorded.
    /// Appends `message_superseded` ahead of the redelivered message.
    ///
    /// Returns the reply segment of an `agent_message_chunk`: one id for every chunk of one
    /// message (the same `messageId`; with none, the run of chunks with none), until a prompt (a
    /// steer) ends it: the turn's id, this daemon run's mark and the segment's number in the turn.
    /// Nothing else ends one. The pane keeps one message in one row across a background task's
    /// note, a subagent's update, a plumbing or plan call (direct.ts; Leo, 2026-11-03: "this chat's
    /// text stream got cut in the middle by a tool call which is weird"), so the segment does too;
    /// a row the pane does cut there is named as before. Stamped on each chunk's record (`stamp_reply_segment`), it names
    /// the reply's row in a client whichever of its chunks a page of the log starts at, so a reply
    /// a page cut is never drawn again under another id when the page before it comes in, and a
    /// reconnect's page draws it under the id it had (Leo, 2026-11-11: "they just appear and
    /// disappear, and then they constantly load and reload").
    pub(super) fn before_agent_update(
        &self,
        session: &Session,
        params: Option<&Value>,
    ) -> Option<String> {
        let update = params.and_then(|p| p.get("update"))?;
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        if kind == "compaction" {
            let fenced = session.compaction_metadata_fenced.load(Ordering::SeqCst);
            match update.get("state").and_then(Value::as_str) {
                Some("running") => session.compacting.store(true, Ordering::SeqCst),
                Some("completed") | Some("failed") if !fenced => {
                    session.compacting.store(false, Ordering::SeqCst)
                }
                _ => {}
            }
        }
        let mut superseded = None;
        let mut retrying = None;
        let mut segment = None;
        // Read before the stream lock: the turn's lock is never taken under it.
        let turn_id =
            (kind == "agent_message_chunk").then(|| session.turn().map(|t| t.turn_id)).flatten();
        {
            let mut st = session.stream.lock().unwrap();
            match kind {
                "agent_message_chunk" => {
                    let id = update.get("messageId").and_then(Value::as_str);
                    if st.reply_segment.is_none() || id != st.segment_message.as_deref() {
                        let turn = turn_id.as_deref().unwrap_or("-");
                        // Numbered within the turn: a new turn starts again at 1.
                        if st.segment_turn.as_deref() != Some(turn) {
                            st.segment_turn = Some(turn.to_owned());
                            st.reply_segments = 0;
                        }
                        st.reply_segments += 1;
                        st.reply_segment =
                            Some(format!("{turn}.{}.{}", segment_boot(), st.reply_segments));
                        st.segment_message = id.map(str::to_owned);
                    }
                    segment = st.reply_segment.clone();
                    if let Some((old, notice)) = st.retry_from.take()
                        && let Some(new) = id
                        && new != old
                    {
                        superseded = Some((old, new.to_owned(), notice));
                    }
                    if id != st.open_message.as_deref() {
                        st.trailing_text.clear();
                        st.trailing_seqs.clear();
                        st.trailing_overflow = false;
                    }
                    st.open_message = id.map(str::to_owned);
                }
                "session_info_update" => {
                    if let Some((will_retry, err)) = codex_error(update) {
                        if will_retry {
                            retrying = Some(super::turn_retry::codex_retry(&err));
                            if let Some(open) = st.open_message.clone() {
                                let notice = err
                                    .get("message")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_owned();
                                st.retry_from = Some((open, notice));
                            }
                        } else {
                            let text = err
                                .get("additionalDetails")
                                .and_then(Value::as_str)
                                .filter(|s| !s.is_empty())
                                .or_else(|| err.get("message").and_then(Value::as_str))
                                .unwrap_or("")
                                .to_owned();
                            st.harness_error = Some(json!({
                                "text": text,
                                "code": err.get("codexErrorInfo").cloned().unwrap_or(Value::Null),
                                "source": "codex",
                            }));
                        }
                    }
                }
                k if NEUTRAL_UPDATES.contains(&k) => {}
                _ => {
                    // A tool call, plan or user chunk ends the message: a
                    // later retry does not abandon it.
                    st.open_message = None;
                    st.retry_from = None;
                    st.trailing_text.clear();
                    st.trailing_seqs.clear();
                    st.trailing_overflow = false;
                }
            }
        }
        // The model request failed and Codex tries again (`turn_retry.rs`).
        if let Some(retry) = retrying {
            self.turn_retrying(session, retry);
        }
        if let Some((old, new, notice)) = superseded {
            let turn_id = session.turn().map(|t| t.turn_id);
            self.append(
                session,
                "mux",
                "message_superseded",
                json!({"oldMessageId": old, "newMessageId": new, "reason": "harness_retry", "source": "codex", "notice": notice, "turnId": turn_id}),
            );
        }
        segment
    }

    /// Called after a live agent `session/update` is recorded.
    pub(super) fn after_agent_update(&self, session: &Session, rec: &EventRecord) {
        if rec.kind != "agent_message_chunk" {
            return;
        }
        let Some(text) = rec.msg.pointer("/params/update/content/text").and_then(Value::as_str)
        else {
            return;
        };
        let mut st = session.stream.lock().unwrap();
        if st.trailing_overflow {
            return;
        }
        if st.trailing_text.len() + text.len() > TRAILING_LIMIT {
            st.trailing_overflow = true;
            st.trailing_text.clear();
            st.trailing_seqs.clear();
            return;
        }
        st.trailing_text.push_str(text);
        st.trailing_seqs.push(rec.seq);
    }

    /// Forget per-turn stream state when a turn starts.
    pub(super) fn reset_stream(&self, session: &Session) {
        *session.stream.lock().unwrap_or_else(|e| e.into_inner()) = StreamState::default();
    }

    /// Error fields for `turn_result`: the text and code of the failure, and
    /// the sequences of trailing `agent_message_chunk` records whose text is
    /// exactly that error (a harness that streamed the error as a message).
    pub(super) fn turn_error_fields(
        &self,
        session: &Session,
        error: Option<(&str, Value)>,
    ) -> serde_json::Map<String, Value> {
        let st = session.stream.lock().unwrap();
        let mut out = serde_json::Map::new();
        let (text, code, source) = match (error, &st.harness_error) {
            (Some((t, c)), _) => (t.to_owned(), c, "agent"),
            (None, Some(h)) => (
                h.get("text").and_then(Value::as_str).unwrap_or("").to_owned(),
                h.get("code").cloned().unwrap_or(Value::Null),
                "codex",
            ),
            (None, None) => return out,
        };
        let streamed = !st.trailing_overflow
            && !st.trailing_seqs.is_empty()
            && !text.trim().is_empty()
            && st.trailing_text.trim() == text.trim();
        out.insert("errorText".into(), Value::String(text));
        out.insert("errorCode".into(), code);
        out.insert("errorSource".into(), Value::String(source.into()));
        if streamed {
            out.insert("errorChunkSeqs".into(), json!(st.trailing_seqs));
        }
        out
    }
}
