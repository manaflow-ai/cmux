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
//! result to the chat that gave it (`hub/tasks.rs`), and `{kind: "turn_cap", turnId, capMs}` on
//! the one notice steered into a turn past its turn cap (`hub/turn_cap.rs`).

use cmux_json::JsonSet as _;
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

/// On a session a Chief host made for one of its turns (optchat-chief `acpmux::turn_tags`): the
/// Chief's participant id (`agent_mux`, `agent_…`), the key the app finds that Chief's name and
/// picture by.
pub const CHIEF_PARTICIPANT_TAG: &str = "cmux.chief.participant";
/// What a Chief's session is called where it is shown: its `mux.label` (the Chief's own name).
const LABEL_TAG: &str = "mux.label";
/// On a message from a Chief's turn session: that Chief's participant id, so the receiving chat
/// draws the Chief's name and picture, not the turn's session name (`optchat-<home>-<n>`,
/// manaflow-ai/cmux#27914).
pub const FROM_CHIEF: &str = "fromChief";

/// `provenance` with its sender's Chief, when the sender is a Chief's turn session of this daemon
/// (`meta_of` reads one by its id): `fromChief` its participant id and `fromName` the Chief's own
/// name. Both kinds a Chief's turn sends with: an `agent_message` (`agents_chat_send` through the
/// cmux daemon's pump, `from` `acp:<id>`) and a `session_message` (`acpmux send` from inside the
/// turn, `from` its id). Any other provenance is left as it is.
pub fn stamp_chief(
    mut provenance: Value,
    meta_of: impl Fn(&str) -> Option<crate::store::SessionMeta>,
) -> Value {
    let kind = provenance.get("kind").and_then(Value::as_str);
    if !matches!(kind, Some("agent_message" | "session_message")) {
        return provenance;
    }
    let Some(from) = provenance.get("from").and_then(Value::as_str) else {
        return provenance;
    };
    let Some(meta) = meta_of(from.strip_prefix("acp:").unwrap_or(from)) else {
        return provenance;
    };
    let live = |key: &str| {
        let tag = meta.tags.get(key)?;
        if tag.expires_at.is_some_and(|e| e <= crate::store::now_ms()) {
            return None;
        }
        Some(tag.value.trim().to_owned()).filter(|v| !v.is_empty() && !v.chars().any(unshown))
    };
    let Some(chief) = live(CHIEF_PARTICIPANT_TAG).filter(|c| c.len() <= MAX_FIELD_BYTES) else {
        return provenance;
    };
    provenance.set(FROM_CHIEF, json!(chief));
    if let Some(label) = live(LABEL_TAG).filter(|l| l.chars().count() <= MAX_NAME_CHARS) {
        provenance.set("fromName", json!(label));
    }
    provenance
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
            meta.set(MESSAGE_META, messages);
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

/// `_meta.acpmux.fromSessionId` and `fromHarness`: which session sent an agent's message and on
/// what harness family (`claude`, `codex`, ...), so a client draws its sender's icon and opens
/// its chat. Display only: nothing decides who may do what by them.
///
/// The daemon binds them; a client never names them. The session a connection proved it runs in
/// (its caller token, `hub/person.rs`) is the sender. Over a peer link (`Origin::Peer`, a peer
/// daemon forwarding its own proven caller's prompt, `server/peer_forward.rs`, or the mesh relay
/// delivering a hub message, `server/mesh_relay.rs`) they are that daemon's word, taken only from
/// a prompt it sent as its own (no `via`): a prompt it forwards for its Web, app or paired-device
/// client names no sender. From anywhere else, or malformed, they are dropped, never refused.
/// They are stamped on the prompt's provenance (`stamp_sender`), so its `queued` and
/// `user_message` records and the queue list carry them, and an edit drops them with it.
pub const FROM_SESSION_ID: &str = "fromSessionId";
/// See [`FROM_SESSION_ID`].
pub const FROM_HARNESS: &str = "fromHarness";

/// The sending session's id and harness family, as far as the daemon bound them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BoundSender {
    pub session_id: Option<String>,
    pub harness: Option<String>,
}

impl BoundSender {
    /// A session of this daemon: its id and its harness family (`web_modes::family_of`).
    pub fn of_session(id: &str, meta: &crate::store::SessionMeta) -> Self {
        Self {
            session_id: fits(id, MAX_FIELD_BYTES).then(|| id.to_owned()),
            harness: Some(crate::web_modes::family_of(meta)).filter(|h| harness_fits(h)),
        }
    }

    fn is_empty(&self) -> bool {
        self.session_id.is_none() && self.harness.is_none()
    }

    /// The `_meta.acpmux` fields that carry it to a peer.
    pub fn mux_fields(&self) -> Value {
        let mut out = Map::new();
        if let Some(id) = &self.session_id {
            out.insert(FROM_SESSION_ID.to_owned(), json!(id));
        }
        if let Some(harness) = &self.harness {
            out.insert(FROM_HARNESS.to_owned(), json!(harness));
        }
        Value::Object(out)
    }
}

fn fits(value: &str, max_bytes: usize) -> bool {
    value.len() <= max_bytes && !value.trim().is_empty() && !value.chars().any(unshown)
}

/// A harness family as acpmux names one: 1 to 64 letters, digits, `.`, `-` or `_`.
fn harness_fits(value: &str) -> bool {
    (1..=MAX_NAME_CHARS).contains(&value.len())
        && value.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

/// The sender a peer link named for a prompt (see [`FROM_SESSION_ID`]): `None` for a prompt it
/// forwarded for a client of its own (`_meta.acpmux.via`), and each field only when well formed.
pub fn peer_sender(params: &Value) -> Option<BoundSender> {
    let mux = params.pointer("/_meta/acpmux")?;
    if mux.get("via").is_some_and(|v| !v.is_null()) {
        return None;
    }
    let field = |k: &str| mux.get(k).and_then(Value::as_str);
    let sender = BoundSender {
        session_id: field(FROM_SESSION_ID)
            .filter(|id| fits(id, MAX_FIELD_BYTES))
            .map(str::to_owned),
        harness: field(FROM_HARNESS).filter(|h| harness_fits(h)).map(str::to_owned),
    };
    (!sender.is_empty()).then_some(sender)
}

/// Takes `fromSessionId` and `fromHarness` out of a prompt's `_meta.acpmux`: what a client wrote
/// never goes on to a peer as this daemon's word.
pub fn drop_sender_fields(params: &mut Value) {
    if let Some(mux) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove(FROM_SESSION_ID);
        mux.remove(FROM_HARNESS);
    }
}

/// `provenance` with the bound sender's fields set (replacing any it had).
pub fn stamp_sender(mut provenance: Value, sender: Option<&BoundSender>) -> Value {
    if let (Some(sender), Some(fields)) = (sender, provenance.as_object_mut()) {
        for (key, value) in [(FROM_SESSION_ID, &sender.session_id), (FROM_HARNESS, &sender.harness)]
        {
            if let Some(value) = value {
                fields.insert(key.to_owned(), json!(value));
            }
        }
    }
    provenance
}

/// The `fromSessionId` and `fromHarness` a prompt's provenance carries (`stamp_sender`).
pub fn sender_of(provenance: Option<&Value>) -> (Option<String>, Option<String>) {
    let field = |k: &str| provenance?.get(k)?.as_str().map(str::to_owned);
    (field(FROM_SESSION_ID), field(FROM_HARNESS))
}

#[cfg(test)]
mod sender_tests {
    use super::*;

    #[test]
    fn a_peer_link_names_a_sender_only_for_its_own_prompt_and_only_well_formed() {
        let sent = |mux: Value| json!({"_meta": {"acpmux": mux}});
        let both = sent(json!({"fromSessionId": "s-1", "fromHarness": "claude"}));
        let bound = BoundSender { session_id: Some("s-1".into()), harness: Some("claude".into()) };
        assert_eq!(peer_sender(&both), Some(bound.clone()));
        assert_eq!(sent(bound.mux_fields())["_meta"]["acpmux"], both["_meta"]["acpmux"]);
        // Forwarded for the peer's own Web, app or device client: no sender.
        let via = sent(json!({"fromSessionId": "s-1", "fromHarness": "claude", "via": "web"}));
        assert_eq!(peer_sender(&via), None);
        // Malformed fields are dropped one by one, never refused.
        let odd = sent(json!({"fromSessionId": "s-1\nx", "fromHarness": "co dex"}));
        assert_eq!(peer_sender(&odd), None);
        let half = sent(json!({"fromSessionId": "s-2", "fromHarness": 7}));
        assert_eq!(peer_sender(&half).and_then(|s| s.session_id).as_deref(), Some("s-2"));
        assert_eq!(peer_sender(&json!({})), None);
    }

    #[test]
    fn a_chief_turn_session_signs_with_the_chief_name_and_id() {
        let tag = |v: &str| crate::store::Tag { value: v.into(), expires_at: None };
        let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": "acpmux.session.v1", "id": "s-1", "name": "optchat-b902d10e-2991",
            "harness": "claude", "family": "claude", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 2,
        }))
        .unwrap();
        let found = |meta: &crate::store::SessionMeta| {
            let meta = meta.clone();
            move |id: &str| (id == "s-1").then(|| meta.clone())
        };
        let pumped = json!({"kind": "agent_message", "from": "acp:s-1", "to": "acp:s-2", "msgId": "m", "threadId": "t"});
        let sent = session_message("s-1", "optchat-b902d10e-2991", "s-2");
        // A session no Chief made: as it was.
        meta.tags.insert(LABEL_TAG.into(), tag("lane"));
        assert_eq!(stamp_chief(sent.clone(), found(&meta)), sent);
        assert_eq!(stamp_chief(pumped.clone(), found(&meta)), pumped);
        // A Chief's turn: the Chief's name and participant id, on both kinds.
        meta.tags.insert(LABEL_TAG.into(), tag("Ops Chief"));
        meta.tags.insert(CHIEF_PARTICIPANT_TAG.into(), tag("agent_ops"));
        for given in [sent, pumped] {
            let stamped = stamp_chief(given.clone(), found(&meta));
            assert_eq!(stamped["fromName"], "Ops Chief");
            assert_eq!(stamped[FROM_CHIEF], "agent_ops");
            assert_eq!(stamped["from"], given["from"]);
        }
        // Another sender, a person's prompt, or a sender this daemon does not have: untouched.
        let other = json!({"kind": "agent_message", "from": "acp:s-9", "to": "acp:s-2", "msgId": "m", "threadId": "t"});
        assert_eq!(stamp_chief(other.clone(), found(&meta)), other);
        let person = json!({"kind": "person_message", "from": "s-1", "fromName": "Ana"});
        assert_eq!(stamp_chief(person.clone(), found(&meta)), person);
    }

    #[test]
    fn a_stamp_replaces_what_the_provenance_had_and_reads_back() {
        let given = json!({"kind": "agent_message", "from": "fromAgent", "fromHarness": "fake"});
        let bound = BoundSender { session_id: Some("s-1".into()), harness: Some("codex".into()) };
        let stamped = stamp_sender(given.clone(), Some(&bound));
        assert_eq!(sender_of(Some(&stamped)), (Some("s-1".into()), Some("codex".into())));
        assert_eq!(stamp_sender(given.clone(), None), given);
        assert_eq!(sender_of(None), (None, None));
        let mut params = json!({"_meta": {"acpmux": {"fromSessionId": "x", "fromHarness": "y", "promptId": "p"}}});
        drop_sender_fields(&mut params);
        assert_eq!(params, json!({"_meta": {"acpmux": {"promptId": "p"}}}));
    }
}
