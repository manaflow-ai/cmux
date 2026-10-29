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

/// The durable copy of a session-to-session message a prompt's in-memory provenance carries
/// (`hub/message_events.rs`). A record keeps it as `_meta._acpmuxMessage`, beside
/// `_meta.provenance` and never inside it, so the provenance a client reads stays the sender's.
pub const MESSAGE_META: &str = "_acpmuxMessage";

/// `record` with `_meta.provenance` when the prompt has one (a `user_message` or `queued`). Its
/// message copies (its own, and each joined message's in a digest) go to `_meta._acpmuxMessage`.
pub fn marked(mut record: Value, provenance: Option<&Value>) -> Value {
    if let (Some(p), Some(fields)) = (provenance, record.as_object_mut()) {
        let mut p = p.clone();
        let messages = take_message_meta(&mut p);
        let mut meta = json!({"provenance": p});
        if let Some(messages) = messages {
            meta[MESSAGE_META] = messages;
        }
        fields.insert("_meta".to_owned(), meta);
    }
    record
}

/// A `queued` or `user_message` record's provenance as the prompt carried it: [`marked`] undone,
/// with its message copies back in place.
pub fn recorded(record: &Value) -> Option<Value> {
    let mut provenance = record.pointer("/_meta/provenance")?.clone();
    if let Some(messages) = record.get("_meta").and_then(|meta| meta.get(MESSAGE_META)) {
        put_message_meta(&mut provenance, messages);
    }
    Some(provenance)
}

/// Takes every message copy out of `provenance`: `{message?, messages?}`, where `messages` holds
/// one entry (or null) per joined message of a digest, in its order.
fn take_message_meta(provenance: &mut Value) -> Option<Value> {
    let fields = provenance.as_object_mut()?;
    let own = fields.remove(MESSAGE_META);
    let joined: Vec<Value> = fields
        .get_mut("messages")
        .and_then(Value::as_array_mut)
        .map(|messages| {
            messages
                .iter_mut()
                .map(|m| m.get_mut("provenance").and_then(take_message_meta).unwrap_or(Value::Null))
                .collect()
        })
        .unwrap_or_default();
    let any_joined = joined.iter().any(|m| !m.is_null());
    if own.is_none() && !any_joined {
        return None;
    }
    let mut taken = Map::new();
    if let Some(own) = own {
        taken.insert("message".to_owned(), own);
    }
    if any_joined {
        taken.insert("messages".to_owned(), Value::Array(joined));
    }
    Some(Value::Object(taken))
}

/// Puts back what [`take_message_meta`] took.
fn put_message_meta(provenance: &mut Value, taken: &Value) {
    let Some(fields) = provenance.as_object_mut() else { return };
    if let Some(own) = taken.get("message") {
        fields.insert(MESSAGE_META.to_owned(), own.clone());
    }
    let joined = taken.get("messages").and_then(Value::as_array);
    let messages = fields.get_mut("messages").and_then(Value::as_array_mut);
    if let (Some(joined), Some(messages)) = (joined, messages) {
        for (message, taken) in messages.iter_mut().zip(joined) {
            if let Some(p) = message.get_mut("provenance").filter(|_| !taken.is_null()) {
                put_message_meta(p, taken);
            }
        }
    }
}

#[cfg(test)]
mod message_meta_tests {
    use super::{MESSAGE_META, marked, recorded};
    use serde_json::json;

    /// A record's provenance is the sender's alone: its message copies (one of its own, one per
    /// joined message of a digest) sit beside it, and reading the record puts them back.
    #[test]
    fn a_record_keeps_its_message_copies_beside_its_provenance() {
        let copy =
            |id: &str| json!({"messageId": id, "sender": {"name": "lane", "sessionId": "s"}});
        let own = json!({"kind": "agent_message", "from": "acp:s", "to": "acp:t", MESSAGE_META: copy("m-0")});
        let digest = json!({"kind": "agent_digest", "messages": [
            {"promptId": "p-1", "from": "lane", "provenance": {"kind": "session_message", MESSAGE_META: copy("m-1")}},
            {"promptId": "p-2", "from": "person"},
            {"promptId": "p-3", "from": "lane", "provenance": {"kind": "session_message"}},
            {"promptId": "p-4", "from": "lane", "provenance": {"kind": "session_message", MESSAGE_META: copy("m-4")}},
        ]});
        for provenance in [own, digest] {
            let record = marked(json!({"promptId": "p"}), Some(&provenance));
            let shown = record.pointer("/_meta/provenance").unwrap();
            assert!(!shown.to_string().contains(MESSAGE_META), "{record}");
            assert!(record.pointer(&format!("/_meta/{MESSAGE_META}")).is_some(), "{record}");
            assert_eq!(recorded(&record), Some(provenance));
        }
        // No copy: the record is as before, and so is what reading it gives.
        let plain = json!({"kind": "agent_message", "from": "acp:s", "to": "acp:t"});
        let record = marked(json!({"promptId": "p"}), Some(&plain));
        assert_eq!(record["_meta"], json!({"provenance": plain}));
        assert_eq!(recorded(&record), Some(plain));
    }
}
