//! The chat as the terminal draws it: built from acpmux's own wire (`session/update` and
//! `_acpmux/event` notifications live, `_acpmux/attach`'s `events` on open and on every
//! reconnect). Every record carries the daemon's `seq`; one already applied is skipped, so a
//! replay after a dropped link draws nothing twice.

use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Item {
    User(String),
    Assistant(String),
    Thought(String),
    Tool { id: String, title: String, status: String },
    Note(String),
}

#[derive(Clone, Debug, Default)]
pub struct Transcript {
    pub items: Vec<Item>,
    last_seq: u64,
    /// The agent's state as the daemon last said: `running`, `ready`, ...
    pub status: String,
    /// Prompts sent from here not yet echoed by the daemon, by promptId.
    pending: Vec<(String, String)>,
    /// Prompts from here the daemon accepted: their `user_message` is already drawn as the echo.
    mine: Vec<String>,
    /// Turns the agent finished, for `--until-idle`. A turn that failed (`turn_error`) counts too:
    /// the daemon sends no `turn_end` for it, and a wait for one would hang to its caller's timeout.
    pub turns_ended: u64,
    /// The last failed turn's reason (`errorKind: error`), so `--until-idle` exits non-zero with it.
    pub turn_error: Option<String>,
}

impl Transcript {
    /// A seq at or below the last applied one is a repeat (a replay after reconnect).
    fn fresh(&mut self, seq: Option<u64>) -> bool {
        match seq {
            Some(s) if s <= self.last_seq => false,
            Some(s) => {
                self.last_seq = s;
                true
            }
            None => true,
        }
    }

    pub fn last_seq(&self) -> u64 {
        self.last_seq
    }

    /// The local echo of a prompt sent from here, replaced by the daemon's `user_message`.
    pub fn echo_prompt(&mut self, prompt_id: &str, text: &str) {
        self.pending.push((prompt_id.to_owned(), text.to_owned()));
        self.items.push(Item::User(text.to_owned()));
    }

    /// Prompts sent but not confirmed: a reconnect resends these under the same promptId, and the
    /// daemon drops a repeat (`resend: true`), so a prompt is never doubled.
    pub fn unconfirmed(&self) -> &[(String, String)] {
        &self.pending
    }

    fn confirm(&mut self, id: &str) {
        self.pending.retain(|(p, _)| p != id);
        if !self.mine.iter().any(|m| m == id) {
            self.mine.push(id.to_owned());
        }
    }

    /// One JSON-RPC notification from the daemon, for `session`.
    pub fn apply_notification(&mut self, session: &str, method: &str, params: &Value) {
        if params.get("sessionId").and_then(Value::as_str) != Some(session) {
            return;
        }
        match method {
            "session/update" => {
                let seq = params.pointer("/_meta/acpmux/seq").and_then(Value::as_u64);
                if self.fresh(seq)
                    && let Some(update) = params.get("update")
                {
                    self.apply_update(update);
                }
            }
            "_acpmux/event" => self.apply_event(params),
            "_acpmux/prompt_accepted" => {
                if let Some(id) = params.get("promptId").and_then(Value::as_str) {
                    self.confirm(id);
                }
            }
            _ => {}
        }
    }

    /// One record of `_acpmux/attach`'s `events`, or a live `_acpmux/event`.
    pub fn apply_event(&mut self, ev: &Value) {
        if !self.fresh(ev.get("seq").and_then(Value::as_u64)) {
            return;
        }
        let dir = ev.get("dir").and_then(Value::as_str).unwrap_or("");
        let kind = ev.get("kind").and_then(Value::as_str).unwrap_or("");
        let msg = ev.get("msg").unwrap_or(&Value::Null);
        if dir == "in" {
            if !kind.ends_with(".replay")
                && msg.get("method").and_then(Value::as_str) == Some("session/update")
                && let Some(update) = msg.pointer("/params/update")
            {
                self.apply_update(update);
            }
            return;
        }
        if dir != "mux" {
            return;
        }
        match kind {
            "user_message" => {
                // The daemon's record keeps the prompt under `_meta._acpmuxMessage.message`.
                let inner = msg.pointer("/_meta/_acpmuxMessage/message").unwrap_or(&Value::Null);
                let field = |k: &str| {
                    msg.get(k).or_else(|| inner.get(k)).and_then(Value::as_str).unwrap_or("")
                };
                let id = match field("promptId") {
                    "" => field("messageId"),
                    id => id,
                };
                let text = field("text").to_owned();
                // Ours, already drawn as the local echo: confirm it instead of drawing it twice.
                if !id.is_empty()
                    && (self.mine.iter().any(|m| m == id)
                        || self.pending.iter().any(|(p, _)| p == id))
                {
                    let id = id.to_owned();
                    self.confirm(&id);
                    return;
                }
                self.items.push(Item::User(clean_prompt(&text)));
            }
            "status" => {
                if let Some(s) = msg.get("status").and_then(Value::as_str) {
                    self.status = s.to_owned();
                }
            }
            "turn_error" => {
                self.turns_ended = self.turns_ended.saturating_add(1);
                let error = msg.get("error").and_then(Value::as_str).unwrap_or("the turn failed");
                let kind = msg
                    .get("errorKind")
                    .or_else(|| msg.pointer("/data/errorKind"))
                    .and_then(Value::as_str);
                let why = match kind {
                    Some(k) => format!("{k}: {error}"),
                    None => error.to_owned(),
                };
                self.items.push(Item::Note(format!("turn failed: {why}")));
                self.turn_error = Some(why);
            }
            "turn_end" => {
                self.turns_ended = self.turns_ended.saturating_add(1);
                self.turn_error = None;
                let reason = msg.get("stopReason").and_then(Value::as_str).unwrap_or("");
                if reason != "end_turn" && !reason.is_empty() {
                    self.items.push(Item::Note(format!("turn ended: {reason}")));
                }
            }
            _ => {}
        }
    }

    fn apply_update(&mut self, update: &Value) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        let text = || update.pointer("/content/text").and_then(Value::as_str).unwrap_or("");
        match kind {
            "agent_message_chunk" => match self.items.last_mut() {
                Some(Item::Assistant(t)) => t.push_str(text()),
                _ => self.items.push(Item::Assistant(text().to_owned())),
            },
            "agent_thought_chunk" => match self.items.last_mut() {
                Some(Item::Thought(t)) => t.push_str(text()),
                _ => self.items.push(Item::Thought(text().to_owned())),
            },
            "tool_call" => {
                let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or("").to_owned();
                let title =
                    update.get("title").and_then(Value::as_str).unwrap_or("tool").to_owned();
                let status =
                    update.get("status").and_then(Value::as_str).unwrap_or("pending").to_owned();
                self.items.push(Item::Tool { id, title, status });
            }
            "tool_call_update" => {
                let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or("");
                for item in self.items.iter_mut().rev() {
                    if let Item::Tool { id: tid, title, status } = item
                        && tid == id
                    {
                        if let Some(s) = update.get("status").and_then(Value::as_str) {
                            *status = s.to_owned();
                        }
                        if let Some(t) = update.get("title").and_then(Value::as_str) {
                            *title = t.to_owned();
                        }
                        break;
                    }
                }
            }
            _ => {}
        }
    }
}

/// The daemon appends a `Sent-by:` provenance line to a prompt; the chat shows what was typed.
fn clean_prompt(text: &str) -> String {
    match text.split_once("\n\nSent-by:") {
        Some((typed, _)) => typed.to_owned(),
        None => text.to_owned(),
    }
}

#[cfg(test)]
#[path = "transcript_tests.rs"]
mod tests;
