//! The acpmux shapes the core reads (the `_acpmux/*` wire, camelCase), and
//! the turn folder: one session's event log folded into turns. Port of
//! `mux/host/src/acpmux-client.ts` (types) and `turns.ts` (folder).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Idle,
    Ready,
    Running,
    Waiting,
    Disconnected,
    Closed,
}

/// `_acpmux/session_changed` and `_acpmux/sessions` rows.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub session_id: String,
    pub name: String,
    #[serde(default)]
    pub harness: String,
    #[serde(default)]
    pub cwd: String,
    pub status: SessionStatus,
    #[serde(default)]
    pub pending_permissions: u64,
    #[serde(default)]
    pub state_seq: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seq: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_count: Option<u64>,
    #[serde(default)]
    pub preview: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_prompt: Option<String>,
    #[serde(default)]
    pub tags: BTreeMap<String, String>,
}

/// One recorded acpmux event (`_acpmux/event`, attach replays, `events`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpmuxEvent {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub seq: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<u64>,
    pub dir: String,
    pub kind: String,
    #[serde(default)]
    pub msg: Map<String, Value>,
}

impl AcpmuxEvent {
    fn is_from_mux(&self) -> bool {
        self.dir == "mux"
    }

    fn prompt_id(&self) -> Option<String> {
        self.msg.get("promptId").and_then(Value::as_str).map(str::to_owned)
    }
}

/// A turn of one acpmux session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Turn {
    /// The seq of its `turn_started` event: unique within the session.
    pub turn_seq: u64,
    /// The promptId of the prompt that started it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_id: Option<String>,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TurnOutput {
    Accepted { prompt_id: String, seq: u64 },
    Started { turn: Turn, seq: u64 },
    Ended { turn: Turn, seq: u64, error: Option<String> },
}

/// Longest turn error kept in a reply.
const ERROR_CHARS: usize = 300;

/// Folds events into turns: `user_message {promptId}`, `turn_started`,
/// `agent_message_chunk` text, then `turn_end` or `turn_error`. Replays and
/// live events fold the same way; events at or below the last seq are ignored.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TurnFolder {
    last_seq: u64,
    current: Option<Turn>,
    last_prompt_id: Option<String>,
}

impl TurnFolder {
    pub fn new(after_seq: u64) -> Self {
        Self { last_seq: after_seq, ..Self::default() }
    }

    pub fn seq(&self) -> u64 {
        self.last_seq
    }

    pub fn running(&self) -> Option<&Turn> {
        self.current.as_ref()
    }

    pub fn apply(&mut self, event: &AcpmuxEvent) -> Vec<TurnOutput> {
        if event.seq > 0 {
            if event.seq <= self.last_seq {
                return Vec::new();
            }
            self.last_seq = event.seq;
        }
        let mut out = Vec::new();
        match (event.is_from_mux(), event.kind.as_str()) {
            (true, "user_message") => {
                let prompt_id = event.prompt_id();
                // A steered prompt joins the running turn; any other starts the next one.
                let steer = event.msg.get("steer") == Some(&Value::Bool(true));
                if !steer || self.current.is_none() {
                    self.last_prompt_id.clone_from(&prompt_id);
                }
                if let Some(prompt_id) = prompt_id {
                    out.push(TurnOutput::Accepted { prompt_id, seq: event.seq });
                }
            }
            (true, "queued") => {
                if let Some(prompt_id) = event.prompt_id() {
                    out.push(TurnOutput::Accepted { prompt_id, seq: event.seq });
                }
            }
            (true, "turn_started") => {
                let turn = Turn {
                    turn_seq: event.seq,
                    prompt_id: self.last_prompt_id.take(),
                    text: String::new(),
                };
                out.push(TurnOutput::Started { turn: turn.clone(), seq: event.seq });
                self.current = Some(turn);
            }
            (_, "agent_message_chunk") => {
                let content = &event.msg.get("params").and_then(|p| p.get("update"));
                let content = content.and_then(|u| u.get("content"));
                if let (Some(current), Some(content)) = (self.current.as_mut(), content)
                    && content.get("type").and_then(Value::as_str) == Some("text")
                    && let Some(text) = content.get("text").and_then(Value::as_str)
                {
                    current.text.push_str(text);
                }
            }
            (true, kind @ ("turn_end" | "turn_error")) => {
                if let Some(turn) = self.current.take() {
                    let error = (kind == "turn_error").then(|| {
                        let text = match event.msg.get("error") {
                            Some(Value::String(text)) => text.clone(),
                            Some(other) => other.to_string(),
                            None => Value::Object(event.msg.clone()).to_string(),
                        };
                        utf16_prefix(&text, ERROR_CHARS)
                    });
                    out.push(TurnOutput::Ended { turn, seq: event.seq, error });
                }
            }
            _ => {}
        }
        out
    }
}

/// The text of the last turn that ended in an event list (a child's last reply).
pub fn last_reply(events: &[AcpmuxEvent]) -> String {
    let mut folder = TurnFolder::default();
    let mut reply = String::new();
    for event in events {
        for output in folder.apply(event) {
            if let TurnOutput::Ended { turn, .. } = output {
                reply = turn.text.trim().to_owned();
            }
        }
    }
    reply
}

/// The first `limit` UTF-16 units (JavaScript `slice(0, limit)`), never
/// splitting a character.
pub(crate) fn utf16_prefix(text: &str, limit: usize) -> String {
    let mut units = 0;
    let mut out = String::new();
    for ch in text.chars() {
        units += ch.len_utf16();
        if units > limit {
            break;
        }
        out.push(ch);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn event(seq: u64, kind: &str, msg: Value) -> AcpmuxEvent {
        let Value::Object(msg) = msg else { panic!() };
        AcpmuxEvent { session_id: None, seq, at: None, dir: "mux".into(), kind: kind.into(), msg }
    }

    fn chunk(seq: u64, text: &str) -> AcpmuxEvent {
        AcpmuxEvent {
            dir: "agent".into(),
            ..event(
                seq,
                "agent_message_chunk",
                json!({"params": {"update": {"content": {"type": "text", "text": text}}}}),
            )
        }
    }

    #[test]
    fn a_turn_folds_prompt_text_and_end() {
        let mut folder = TurnFolder::default();
        assert_eq!(
            folder.apply(&event(1, "user_message", json!({"promptId": "msg_1"}))),
            vec![TurnOutput::Accepted { prompt_id: "msg_1".into(), seq: 1 }]
        );
        let started = folder.apply(&event(2, "turn_started", json!({})));
        assert!(
            matches!(&started[..], [TurnOutput::Started { turn, .. }] if turn.prompt_id.as_deref() == Some("msg_1"))
        );
        folder.apply(&chunk(3, "Hel"));
        folder.apply(&chunk(4, "lo"));
        let ended = folder.apply(&event(5, "turn_end", json!({})));
        assert_eq!(
            ended,
            vec![TurnOutput::Ended {
                turn: Turn { turn_seq: 2, prompt_id: Some("msg_1".into()), text: "Hello".into() },
                seq: 5,
                error: None
            }]
        );
        assert!(
            folder.apply(&event(5, "turn_end", json!({}))).is_empty(),
            "replay below the cursor"
        );
    }

    #[test]
    fn a_steered_prompt_joins_the_running_turn() {
        let mut folder = TurnFolder::default();
        folder.apply(&event(1, "user_message", json!({"promptId": "a"})));
        folder.apply(&event(2, "turn_started", json!({})));
        folder.apply(&event(3, "user_message", json!({"promptId": "b", "steer": true})));
        let ended = folder.apply(&event(4, "turn_error", json!({"error": "boom"})));
        assert!(
            matches!(&ended[..], [TurnOutput::Ended { turn, error: Some(e), .. }] if turn.prompt_id.as_deref() == Some("a") && e == "boom")
        );
    }

    #[test]
    fn last_reply_is_the_last_ended_turn() {
        let events = vec![
            event(1, "turn_started", json!({})),
            chunk(2, " first "),
            event(3, "turn_end", json!({})),
            event(4, "turn_started", json!({})),
            chunk(5, "second"),
            event(6, "turn_end", json!({})),
        ];
        assert_eq!(last_reply(&events), "second");
    }
}
