//! A prompt's provenance (`_meta.acpmux.provenance` on `session/prompt`, cx-55d27): who sent
//! a prompt that is not the person's own, today one agent's message to another (`cmux agent
//! message`): `{kind: "agent_message", from, fromName?, to, msgId, threadId, replyTo?}`.
//! acpmux records it as `_meta.provenance` on the prompt's `user_message` (and its `queued`
//! record), so a client shows the prompt as that agent's message instead of as the person's
//! words. The agent gets the prompt's blocks only.
//!
//! Only the unix socket may send it (`remote_guard.rs` refuses every other origin with
//! `provenance.origin_refused`), so a remote client cannot pass its words off as an agent's.
//! The app's own pane included: its reply in place to an agent message is no prompt, it is
//! checked and signed by `_acpmux/app_reply` (`server/app_reply.rs`) and sent by the app as the
//! replying chat's cmux agent message, which the daemon's pump delivers here.
//! A queued prompt keeps it, across a restart too (`queue.rs`); an edit of a waiting prompt
//! (`_acpmux/queue_edit`) drops it: the person rewrote the prompt.
//!
//! The hub sets two more kinds itself, never taken from a client: `{kind: "offer_result",
//! offerId, childSessionId, title}` on the prompt that brings a suggested task's first reply
//! back to the chat that offered it (`hub/offer_results.rs`, cx-lo9yf), `{kind:
//! "auto_resume", promptId, attempt, turnId}` on the prompt that continues a turn a
//! connection error cut off (`hub/auto_resume.rs`), `{kind: "session_message", from,
//! fromName, to}` on a prompt another session sent with none (`session_message` below), and
//! `{kind: "task_result", from, fromName, to, taskId, state}` on the prompt that brings a task's
//! result to the chat that gave it (`hub/tasks.rs`).

use serde_json::{Map, Value, json};

use crate::rpc::RpcError;

/// Longest id or address field, in bytes.
pub const MAX_FIELD_BYTES: usize = 256;
/// Longest sender name, in characters (`cmux agent message --from`).
pub const MAX_NAME_CHARS: usize = 64;

/// The fields a provenance names, each a one-line string, and whether it is required.
const FIELDS: &[(&str, bool)] = &[
    ("from", true),
    ("fromName", false),
    ("to", true),
    ("msgId", true),
    ("threadId", true),
    ("replyTo", false),
];

fn refusal(reason: &str, message: &str) -> RpcError {
    RpcError::invalid_params(message.to_owned()).with_data(json!({"reason": reason}))
}

/// Whether `meta` (`_meta.acpmux`) carries a provenance.
pub fn present(meta: Option<&Value>) -> bool {
    meta.and_then(|m| m.get("provenance")).is_some_and(|p| !p.is_null())
}

/// The refusal for a provenance sent over any connection but the unix socket.
pub fn origin_refused() -> RpcError {
    refusal(
        "provenance.origin_refused",
        "a prompt provenance is accepted only over the local unix socket",
    )
}

/// The refusal for `_acpmux/prompt_withdraw` over any connection but the unix socket: only the
/// socket that may say an agent sent a message may take one back (`hub/withdraw.rs`).
pub fn withdraw_origin_refused() -> RpcError {
    refusal(
        "withdraw.origin_refused",
        "withdrawing an agent message is accepted only over the local unix socket",
    )
}

/// Who sent a `session/prompt`, as far as its provenance goes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Sender {
    /// The unix socket: any provenance.
    Local,
    /// Anything else: none.
    Other,
}

/// The provenance of a `session/prompt`'s `params`, with only the fields above: `None` when
/// absent or null. `server/app_reply.rs` checks the app pane's reply in place with it too, as a
/// unix-socket provenance, before `Hub::app_reply_fits` checks the message it answers.
pub fn of(params: &Value, sender: Sender) -> Result<Option<Value>, RpcError> {
    let raw = match params.pointer("/_meta/acpmux/provenance") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(raw)) => raw,
        Some(_) => return Err(refusal("provenance.value_refused", "provenance must be an object")),
    };
    if sender != Sender::Local {
        return Err(origin_refused());
    }
    if raw.get("kind").and_then(Value::as_str) != Some("agent_message") {
        return Err(refusal("provenance.value_refused", "provenance kind must be agent_message"));
    }
    let mut out = Map::new();
    out.insert("kind".to_owned(), json!("agent_message"));
    for &(key, required) in FIELDS {
        let value = match raw.get(key) {
            None | Some(Value::Null) if !required => continue,
            Some(Value::String(value)) if valid(key, value) => value,
            _ => {
                let need = if key == "fromName" {
                    format!("1 to {MAX_NAME_CHARS} characters")
                } else {
                    format!("1 to {MAX_FIELD_BYTES} bytes")
                };
                let message = format!("provenance {key} must be one line of {need}");
                return Err(refusal("provenance.value_refused", &message));
            }
        };
        out.insert(key.to_owned(), json!(value));
    }
    Ok(Some(Value::Object(out)))
}

fn valid(key: &str, value: &str) -> bool {
    let fits = if key == "fromName" {
        value.chars().count() <= MAX_NAME_CHARS
    } else {
        value.len() <= MAX_FIELD_BYTES
    };
    fits && !value.trim().is_empty() && !value.chars().any(unshown)
}

/// A character that breaks the one line or changes how it reads: a control, a line or
/// paragraph separator, or a bidi or zero-width format mark.
fn unshown(c: char) -> bool {
    c.is_control()
        || (c.is_whitespace() && c != ' ')
        || matches!(
            c,
            '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}'
        )
}

/// The provenance of a suggested task's result (`hub/offer_results.rs`): the offer, the chat
/// it started, and the task's title.
pub fn offer_result(offer_id: &str, child_session_id: &str, title: &str) -> Value {
    json!({"kind": "offer_result", "offerId": offer_id, "childSessionId": child_session_id, "title": title})
}

/// The provenance of a prompt a session sent another with none of its own: `acpmux send` (or
/// any client) run inside an acpmux session, which proved that session with its caller token
/// (`hub/person.rs` (a), `server/requests.rs`). Never for the person, nor a prompt to the sender
/// itself. `from` is the sender's session id, so the receiver's transcript opens its chat.
pub fn session_message(from: &str, from_name: &str, to: &str) -> Value {
    json!({"kind": "session_message", "from": from, "fromName": from_name, "to": to})
}

/// The provenance of a task's result on the prompt that brings it to the chat that gave the task
/// (`hub/tasks.rs`): from the lane's session, `from` its id as in [`session_message`].
pub fn task_result(from: &str, from_name: &str, to: &str, task_id: &str, state: &str) -> Value {
    json!({"kind": "task_result", "from": from, "fromName": from_name, "to": to, "taskId": task_id, "state": state})
}

/// What `from` says in [`named_sender`]: the sender named itself and is no address here.
pub const NAMED_SENDER: &str = "fromAgent";

/// The provenance of a prompt whose sender named itself (`_meta.acpmux.fromAgent`) with no
/// provenance and no caller proof here: `acpmux send --from NAME`, `ACPMUX_FROM`, a peer daemon
/// forwarding a prompt its own session sent (`server/peer_forward.rs`; `cli/sender.rs`). An
/// agent's message, never the person's own: the transcript draws its sender's
/// chip, found by name (`from` opens no chat, as a person at a shell's `cli` does not).
pub fn named_sender(name: &str, to: &str) -> Value {
    json!({"kind": "agent_message", "from": NAMED_SENDER, "fromName": name, "to": to})
}

/// The machine a person's own `acpmux send` ran on (`_meta.acpmux.cliHost`, `cli/sender.rs`), when
/// it reads as a host name: 1 to 64 letters, digits, `.`, `-` or `_`.
pub fn cli_host(params: &Value) -> Option<&str> {
    let host = params.pointer("/_meta/acpmux/cliHost")?.as_str()?;
    let fits = (1..=MAX_NAME_CHARS).contains(&host.len())
        && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'));
    fits.then_some(host)
}

/// `record` with `_meta.provenance` when the prompt has one (a `user_message` or `queued`).
pub fn marked(mut record: Value, provenance: Option<&Value>) -> Value {
    if let (Some(p), Some(fields)) = (provenance, record.as_object_mut()) {
        fields.insert("_meta".to_owned(), json!({"provenance": p}));
    }
    record
}
