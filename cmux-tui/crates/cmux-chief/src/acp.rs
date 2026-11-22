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
/// It reads leniently, as the TypeScript core does: a missing (or null) seq
/// is 0 (folded, never deduped), a missing msg is `{}`, and a seq or at that
/// is not a non-negative integer up to 2^53 - 1 marks the event invalid
/// (both cores drop it with a log) instead of failing the parse.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "RawAcpmuxEvent")]
pub struct AcpmuxEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub seq: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at: Option<u64>,
    pub dir: String,
    pub kind: String,
    pub msg: Map<String, Value>,
    /// False when seq or at was present but not a valid count.
    #[serde(skip)]
    pub valid: bool,
}

/// The wire shape of an event before its counts are checked.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawAcpmuxEvent {
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    seq: Option<Value>,
    #[serde(default)]
    at: Option<Value>,
    #[serde(default)]
    dir: Option<Value>,
    #[serde(default)]
    kind: Option<Value>,
    #[serde(default)]
    msg: Option<Value>,
}

/// JavaScript's `Number.MAX_SAFE_INTEGER`.
const MAX_SAFE_INTEGER: u64 = (1 << 53) - 1;

/// A count on the acpmux wire (seq, at, log id): a non-negative safe
/// integer, else `None` (a fraction, a negative number, a string).
pub fn lenient_count_value(value: &Value) -> Option<u64> {
    count(Some(value.clone())).ok().flatten()
}

/// An absent or null count is `Ok(None)`; a non-negative safe integer is
/// `Ok(Some)`; anything else is `Err`. JSON has one number type, so an
/// integer-valued float (`1.0`, `3e0`, `-0`) is that integer, as JavaScript's
/// `Number.isSafeInteger` reads it after `JSON.parse`.
fn count(value: Option<Value>) -> Result<Option<u64>, ()> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => match (number.as_u64(), number.as_f64()) {
            (Some(n), _) => Some(n).filter(|n| *n <= MAX_SAFE_INTEGER).map(Some).ok_or(()),
            // In range and integral (`-0.0` included), so the cast is exact.
            (None, Some(float))
                if float.fract() == 0.0 && (0.0..=MAX_SAFE_INTEGER as f64).contains(&float) =>
            {
                Ok(Some(float as u64))
            }
            _ => Err(()),
        },
        Some(_) => Err(()),
    }
}

impl From<RawAcpmuxEvent> for AcpmuxEvent {
    fn from(raw: RawAcpmuxEvent) -> Self {
        let text = |value: Option<Value>| match value {
            Some(Value::String(text)) => text,
            _ => String::new(),
        };
        let (seq, at) = (count(raw.seq), count(raw.at));
        let valid = seq.is_ok() && at.is_ok();
        Self {
            session_id: raw.session_id,
            seq: seq.ok().flatten().unwrap_or(0),
            at: at.ok().flatten(),
            dir: text(raw.dir),
            kind: text(raw.kind),
            msg: match raw.msg {
                Some(Value::Object(msg)) => msg,
                _ => Map::new(),
            },
            valid,
        }
    }
}

impl AcpmuxEvent {
    fn is_from_mux(&self) -> bool {
        self.dir == "mux"
    }

    /// The event's prompt id: a non-empty string, else none.
    fn prompt_id(&self) -> Option<String> {
        self.msg
            .get("promptId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
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
        if !event.valid {
            return Vec::new();
        }
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
                    let error =
                        (kind == "turn_error").then(|| turn_error_text(&event.msg)).flatten();
                    out.push(TurnOutput::Ended { turn, seq: event.seq, error });
                }
            }
            _ => {}
        }
        out
    }
}

/// The error text of a `turn_error` event's `msg`, as every Chief brain
/// posts it (the shared behavior corpus): JavaScript
/// `String(msg.error ?? canonicalJson(msg))`, cut at `ERROR_CHARS` UTF-16
/// units; an empty error is no error.
pub fn turn_error_text(msg: &Map<String, Value>) -> Option<String> {
    let text = match msg.get("error") {
        None | Some(Value::Null) => Value::Object(msg.clone()).to_string(),
        Some(error) => js_string(error),
    };
    Some(utf16_prefix(&text, ERROR_CHARS)).filter(|error| !error.is_empty())
}

/// The text of the last turn that ended in an event list (a child's last reply).
pub fn last_reply(events: &[AcpmuxEvent]) -> String {
    let mut folder = TurnFolder::default();
    let mut reply = String::new();
    for event in events {
        for output in folder.apply(event) {
            if let TurnOutput::Ended { turn, .. } = output {
                reply = js_trim(&turn.text).to_owned();
            }
        }
    }
    reply
}

/// JavaScript whitespace (`\s`, `String.prototype.trim`): WhiteSpace and
/// LineTerminator. Unlike Rust's `char::is_whitespace` it has U+FEFF and not
/// U+0085.
pub(crate) fn is_js_whitespace(ch: char) -> bool {
    matches!(ch, '\t'..='\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}')
        || matches!(ch, '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}')
}

/// JavaScript `String.prototype.trim`.
pub(crate) fn js_trim(text: &str) -> &str {
    text.trim_matches(is_js_whitespace)
}

/// JavaScript `String(value)` for a JSON value: an object is
/// `[object Object]`, an array joins its items with commas (null items are
/// empty). Numbers use Rust's shortest form, which is JavaScript's for
/// integers and for floats from 1e-6 to 1e21.
pub(crate) fn js_string(value: &Value) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => match (number.as_i64(), number.as_u64(), number.as_f64()) {
            (Some(int), _, _) => int.to_string(),
            (None, Some(int), _) => int.to_string(),
            (None, None, Some(float)) => float.to_string(),
            (None, None, None) => number.to_string(),
        },
        Value::String(text) => text.clone(),
        Value::Array(items) => items
            .iter()
            .map(|item| if item.is_null() { String::new() } else { js_string(item) })
            .collect::<Vec<_>>()
            .join(","),
        Value::Object(_) => "[object Object]".to_owned(),
    }
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
        AcpmuxEvent {
            session_id: None,
            seq,
            at: None,
            dir: "mux".into(),
            kind: kind.into(),
            msg,
            valid: true,
        }
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
    fn an_integer_valued_float_count_is_that_integer() {
        // JSON has one number type: JavaScript's JSON.parse reads 1.0 as 1.
        let read = |text: &str| serde_json::from_str::<AcpmuxEvent>(text).expect("event");
        let event = read(r#"{"seq": 1.0, "at": 1790985600002.0, "dir": "mux", "kind": "x"}"#);
        assert!(event.valid);
        assert_eq!((event.seq, event.at), (1, Some(1_790_985_600_002)));
        assert_eq!(read(r#"{"seq": 3e0, "kind": "x"}"#).seq, 3);
        assert_eq!(read(r#"{"seq": -0.0, "kind": "x"}"#).seq, 0, "-0 is 0, as in JavaScript");
        assert_eq!(read(r#"{"seq": 9007199254740991.0, "kind": "x"}"#).seq, MAX_SAFE_INTEGER);
        for bad in ["2.5", "-1", "-1.0", "9007199254740992.0", "1e300", "\"1\""] {
            let event = read(&format!(r#"{{"seq": {bad}, "kind": "x"}}"#));
            assert!(!event.valid, "seq {bad} is not a count");
        }
        assert_eq!(lenient_count_value(&json!(5.0)), Some(5));
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
