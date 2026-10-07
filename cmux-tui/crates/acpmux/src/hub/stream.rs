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

impl Hub {
    /// Called for a live agent `session/update` before it is recorded.
    /// Appends `message_superseded` ahead of the redelivered message.
    pub(super) fn before_agent_update(&self, session: &Session, params: Option<&Value>) {
        let Some(update) = params.and_then(|p| p.get("update")) else { return };
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        let mut superseded = None;
        {
            let mut st = session.stream.lock().unwrap();
            match kind {
                "agent_message_chunk" => {
                    let id = update.get("messageId").and_then(Value::as_str);
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
        if let Some((old, new, notice)) = superseded {
            let turn_id = session.turn().map(|t| t.turn_id);
            self.append(
                session,
                "mux",
                "message_superseded",
                json!({"oldMessageId": old, "newMessageId": new, "reason": "harness_retry", "source": "codex", "notice": notice, "turnId": turn_id}),
            );
        }
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
        *session.stream.lock().unwrap() = StreamState::default();
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
