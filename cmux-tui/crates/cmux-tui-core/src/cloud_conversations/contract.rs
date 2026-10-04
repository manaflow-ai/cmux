//! Request and reply mapping between the daemon commands and the cloud's
//! Home routes (home-cloud-proxy.md sections 4 and 7). Pure: no I/O.

use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::CloudError;
use super::service::HttpReply;

/// Op kinds `cloud-conversation-op` forwards. Every other kind is refused
/// before any network call (default deny).
pub const CLOUD_OP_KINDS: &[&str] = &[
    "dm.open",
    "conversation.create",
    "participants.add",
    "participants.remove",
    "message.send",
    "message.edit",
    "message.retract",
    "reaction.add",
    "reaction.remove",
    "read_cursor.set",
    "title.set",
    "invite.create",
];

/// Kinds that create or open a conversation and therefore name none.
const UNSCOPED_KINDS: &[&str] = &["dm.open", "conversation.create"];
const ORIGINS: &[&str] = &["user", "cli", "mcp", "script", "remote"];
const MAX_KEY_CHARS: usize = 256;
pub(crate) const MAX_TAIL: u32 = 50;
pub(crate) const MAX_PAGE: u32 = 200;
/// home-core `TABLE_MSG` and `TABLE_INV`, inbox `TABLE_ENTRY`.
const TABLE_MSG: &str = "msg";
const TABLE_INV: &str = "inv";
const TABLE_ENTRY: &str = "entry";

/// An upstream stream the daemon can subscribe to.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Target {
    Inbox,
    Conversation(String),
}

impl Target {
    pub(crate) fn scope(&self) -> &'static str {
        match self {
            Self::Inbox => "inbox",
            Self::Conversation(_) => "conversation",
        }
    }

    /// The upstream WebSocket path.
    pub(crate) fn wire_path(&self) -> String {
        match self {
            Self::Inbox => "/v1/wire/user".to_string(),
            Self::Conversation(id) => format!("/v1/wire/conv/{id}"),
        }
    }
}

/// `conv_<26>` or `conv_dm_<26>` in Crockford base32 (the Worker's
/// CONVERSATION_ID). Checked before an id enters a URL path.
pub fn valid_conversation_id(id: &str) -> bool {
    let suffix = id.strip_prefix("conv_dm_").or_else(|| id.strip_prefix("conv_"));
    suffix.is_some_and(|suffix| {
        suffix.len() == 26
            && suffix.bytes().all(|byte| {
                byte.is_ascii_digit()
                    || (byte.is_ascii_uppercase() && !matches!(byte, b'I' | b'L' | b'O' | b'U'))
            })
    })
}

pub(crate) fn require_conversation(id: &str) -> Result<(), CloudError> {
    if valid_conversation_id(id) {
        Ok(())
    } else {
        Err(CloudError::BadRequest(format!("conversation {id:?} is not a conversation id")))
    }
}

/// `cloud-conversation-op` params.
#[derive(Debug, Clone, Deserialize)]
pub struct OpRequest {
    #[serde(default)]
    pub conversation: Option<String>,
    pub idempotency_key: String,
    #[serde(default)]
    pub origin: Option<String>,
    pub op: Value,
}

/// The `POST /v1/ops` body for one op: `{op, params, idempotency_key, origin}`.
/// The op's fields go to the owner unchanged; only `kind` and `conversation`
/// move.
pub(crate) fn op_body(request: &OpRequest) -> Result<Value, CloudError> {
    let key = &request.idempotency_key;
    if key.is_empty() || key.chars().count() > MAX_KEY_CHARS {
        return Err(CloudError::BadRequest(format!(
            "idempotency_key must be 1-{MAX_KEY_CHARS} characters"
        )));
    }
    let origin = request.origin.as_deref().unwrap_or("cli");
    if !ORIGINS.contains(&origin) {
        return Err(CloudError::BadRequest(format!("origin must be one of {ORIGINS:?}")));
    }
    let Value::Object(fields) = &request.op else {
        return Err(CloudError::BadRequest("op must be an object tagged by kind".into()));
    };
    let Some(kind) = fields.get("kind").and_then(Value::as_str) else {
        return Err(CloudError::BadRequest("op.kind must be a string".into()));
    };
    if !CLOUD_OP_KINDS.contains(&kind) {
        return Err(CloudError::daemon_reject(
            "unsupported_op",
            format!("{kind} is not a cloud conversation op"),
        ));
    }
    let mut params: Map<String, Value> =
        fields.iter().filter(|(name, _)| name.as_str() != "kind").map(|(k, v)| (k.clone(), v.clone())).collect();
    if params.contains_key("conversation") {
        return Err(CloudError::BadRequest(
            "name the conversation at the top level, not inside op".into(),
        ));
    }
    let unscoped = UNSCOPED_KINDS.contains(&kind);
    match (&request.conversation, unscoped) {
        (Some(_), true) => {
            return Err(CloudError::BadRequest(format!("{kind} does not name a conversation")));
        }
        (None, false) => {
            return Err(CloudError::BadRequest(format!("{kind} needs a conversation")));
        }
        (Some(conversation), false) => {
            require_conversation(conversation)?;
            params.insert("conversation".into(), Value::String(conversation.clone()));
        }
        (None, true) => {}
    }
    Ok(json!({"op": kind, "params": params, "idempotency_key": key, "origin": origin}))
}

pub(crate) fn read_body(op: &str, params: Value) -> Value {
    json!({"op": op, "params": params})
}

/// `{code, message, retryable}` of an error body, top level or under `error`.
fn error_fields(body: &Value) -> Option<(String, String, bool)> {
    let error = body.get("error").filter(|error| error.is_object()).unwrap_or(body);
    let code = error.get("code")?.as_str()?.to_string();
    let message = error.get("message").and_then(Value::as_str).unwrap_or_default().to_string();
    let retryable = error.get("retryable").and_then(Value::as_bool).unwrap_or(false);
    Some((code, message, retryable))
}

/// HTTP status handling shared by reads and mutations.
fn classify(reply: &HttpReply) -> Result<(), CloudError> {
    match reply.status {
        200..=299 => Ok(()),
        401 => Err(CloudError::Unauthenticated),
        400..=499 => match error_fields(&reply.body) {
            Some((code, message, retryable)) => Err(CloudError::Rejected { code, message, retryable }),
            None => Err(CloudError::Unavailable(format!("HTTP {} without an error body", reply.status))),
        },
        status => Err(CloudError::Unavailable(format!("HTTP {status}"))),
    }
}

/// A `POST /v1/ops` reply as `cloud-conversation-op` data, or the owner's
/// reject.
pub(crate) fn mutation_data(reply: HttpReply) -> Result<Value, CloudError> {
    classify(&reply)?;
    let body = reply.body;
    match body.get("ok").and_then(Value::as_bool) {
        Some(true) => {}
        Some(false) => {
            return Err(match error_fields(&body) {
                Some((code, message, retryable)) => CloudError::Rejected { code, message, retryable },
                None => CloudError::Unavailable("a refused op without an error".into()),
            });
        }
        None => return Err(CloudError::Unavailable("malformed op reply".into())),
    }
    let value = body.get("value").cloned().unwrap_or(Value::Null);
    let mut data = Map::new();
    for lifted in ["rev", "seq", "change"] {
        if let Some(field) = value.get(lifted) {
            data.insert(lifted.into(), field.clone());
        }
    }
    data.insert("value".into(), value);
    data.insert("replayed".into(), body.get("replayed").cloned().unwrap_or(Value::Bool(false)));
    for envelope in ["transaction", "stream"] {
        data.insert(
            envelope.into(),
            body.get(envelope).cloned().unwrap_or_else(|| Value::String(String::new())),
        );
    }
    data.insert("sequence".into(), body.get("sequence").cloned().unwrap_or(json!(0)));
    Ok(Value::Object(data))
}

/// A `POST /v1/read` reply: `(value, revision)`.
pub(crate) fn read_value(reply: HttpReply) -> Result<(Value, Value), CloudError> {
    classify(&reply)?;
    let Some(value) = reply.body.get("value") else {
        return Err(CloudError::Unavailable("malformed read reply".into()));
    };
    let revision = reply.body.get("revision").cloned().unwrap_or(Value::String(String::new()));
    Ok((value.clone(), revision))
}

pub(crate) fn inbox_list_data(value: Value, revision: Value) -> Result<Value, CloudError> {
    let entries = value
        .get("entries")
        .filter(|entries| entries.is_array())
        .cloned()
        .ok_or_else(|| CloudError::Unavailable("inbox.list without entries".into()))?;
    Ok(json!({"entries": entries, "revision": revision}))
}

pub(crate) fn history_data(value: Value) -> Result<Value, CloudError> {
    let messages = value
        .get("messages")
        .filter(|messages| messages.is_array())
        .cloned()
        .ok_or_else(|| CloudError::Unavailable("conversation.history without messages".into()))?;
    let has_more = value.get("has_more").and_then(Value::as_bool).unwrap_or(false);
    Ok(json!({"messages": messages, "has_more": has_more}))
}

/// An invite as subscribers see it: never its token hash.
fn public_invite(invite: &Value) -> Value {
    let mut invite = invite.clone();
    if let Value::Object(fields) = &mut invite {
        fields.remove("token_hash");
    }
    invite
}

/// home-core `summary(head, last)`: the head with owner `cloud`, without the
/// loop guard counters, import provenance or invite token hashes.
pub(crate) fn summary_from_head(head: &Value, last_message: Option<&Value>) -> Value {
    let mut summary = Map::new();
    summary.insert("owner".into(), Value::String("cloud".into()));
    for field in ["id", "title", "participants", "last_seq", "rev", "created_at", "updated_at"] {
        summary.insert(field.into(), head.get(field).cloned().unwrap_or(Value::Null));
    }
    if let Some(last) = last_message {
        summary.insert("last_message".into(), last.clone());
    }
    summary.insert(
        "read_cursors".into(),
        head.get("read_cursors").cloned().unwrap_or_else(|| json!({})),
    );
    for field in ["kind", "team", "created_by", "state", "settings", "retention_days"] {
        if let Some(value) = head.get(field).filter(|value| !value.is_null()) {
            summary.insert(field.into(), value.clone());
        }
    }
    if let Some(invites) = head.get("invites").and_then(Value::as_array) {
        summary.insert("invites".into(), Value::Array(invites.iter().map(public_invite).collect()));
    }
    Value::Object(summary)
}

fn seq_of(message: &Value) -> u64 {
    message.get("seq").and_then(Value::as_u64).unwrap_or(0)
}

/// Summary, messages, rev and stream seq of an owner snapshot frame
/// (`{t:"snapshot", stream, seq, state, rows:{table:"msg", rows:[{key, n, row}]}}`).
pub(crate) fn snapshot_parts(frame: &Value) -> Result<(Value, Vec<Value>, u64, u64), CloudError> {
    let head = frame.get("state").filter(|state| state.is_object()).ok_or_else(|| {
        CloudError::daemon_reject("unknown_conversation", "the conversation has no state")
    })?;
    let seq = frame
        .get("seq")
        .and_then(Value::as_u64)
        .ok_or_else(|| CloudError::Unavailable("snapshot without seq".into()))?;
    let mut messages: Vec<Value> = frame
        .get("rows")
        .filter(|rows| rows.get("table").and_then(Value::as_str) == Some(TABLE_MSG))
        .and_then(|rows| rows.get("rows"))
        .and_then(Value::as_array)
        .map(|rows| rows.iter().filter_map(|row| row.get("row").cloned()).collect())
        .unwrap_or_default();
    messages.sort_by_key(seq_of);
    let rev = head.get("rev").and_then(Value::as_u64).unwrap_or(0);
    let summary = summary_from_head(head, messages.last());
    Ok((summary, messages, rev, seq))
}

pub(crate) fn snapshot_data(frame: &Value) -> Result<Value, CloudError> {
    let (summary, messages, rev, seq) = snapshot_parts(frame)?;
    Ok(json!({"conversation": summary, "messages": messages, "rev": rev, "seq": seq}))
}

/// The participant id of an event's public actor (home-core `actorOf`).
fn actor_participant(actor: &Value) -> Option<String> {
    let prefixed = |prefix: &str, id: &str| {
        if id.starts_with(prefix) { id.to_string() } else { format!("{prefix}{id}") }
    };
    if let Some(agent) = actor.get("agent").and_then(Value::as_str) {
        return Some(prefixed("agent_", agent));
    }
    actor.get("user").and_then(Value::as_str).map(|user| prefixed("user_", user))
}

fn upserts<'a>(effects: &'a Value, table: &'a str) -> impl Iterator<Item = &'a Value> + 'a {
    effects
        .get("writes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(move |write| {
            write.get("table").and_then(Value::as_str) == Some(table)
                && write.get("op").and_then(Value::as_str) == Some("upsert")
        })
        .filter_map(|write| write.get("row"))
}

/// `(rev, change)` of a conversation event frame, in the local owner's
/// `Change` shapes. `None` when the frame carries no effects to map (the
/// daemon then resyncs with a snapshot).
pub(crate) fn conversation_change(frame: &Value) -> Option<(u64, Value)> {
    let op = frame.get("op")?.as_str()?;
    if op.starts_with("conversation.import") {
        return None;
    }
    let effects = frame.get("effects")?;
    let head = effects.get("state").filter(|state| state.is_object())?;
    let rev = head.get("rev").and_then(Value::as_u64)?;
    let change = if let Some(message) = upserts(effects, TABLE_MSG).last() {
        let kind = if op == "message.send" { "message" } else { "message-updated" };
        json!({"kind": kind, "message": message})
    } else if op == "read_cursor.set" {
        let participant = actor_participant(frame.get("actor")?)?;
        let seq = head
            .get("read_cursors")
            .and_then(|cursors| cursors.get(&participant))
            .and_then(Value::as_u64)
            .or_else(|| frame.get("params")?.get("seq")?.as_u64())?;
        json!({"kind": "read-cursor", "participant": participant, "seq": seq})
    } else if op == "invite.delivery.report"
        && let Some(invite) = upserts(effects, TABLE_INV).last()
    {
        json!({"kind": "invite", "conversation": head.get("id"), "invite": public_invite(invite)})
    } else {
        json!({"kind": "conversation", "conversation": summary_from_head(head, None)})
    };
    Some((rev, change))
}

/// The inbox entries an inbox event frame wrote; `None` without effects.
pub(crate) fn inbox_entries(frame: &Value) -> Option<Vec<Value>> {
    let effects = frame.get("effects")?;
    Some(upserts(effects, TABLE_ENTRY).cloned().collect())
}
