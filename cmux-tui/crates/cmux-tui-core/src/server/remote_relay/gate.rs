//! The frame-level gate of a remote stream (server-remote-conversations.md
//! sections 3, 4 and 7). It sees every frame before anything parses or
//! dispatches it, so the resource-protocol, `loopback-*`, `scheduler.*` and
//! `url-open` routers and binary or malformed frames never see a remote
//! frame. Default deny: a command passes only by its exact name, with exactly
//! the params listed here. A new daemon command is refused until it is added
//! with an analysis.

use serde_json::{Map, Value};

/// The capabilities a remote client may declare (`set-client-info`).
pub(crate) const REMOTE_CAPABILITIES: &[&str] = &["local-conversations-v1"];

/// Params that carry a command to run. Refused on every method.
pub(crate) const COMMAND_PARAMS: &[&str] =
    &["initial_command", "command", "tmux_start_command", "pane_start_command"];

/// Section 4: the remote commands and the exact params each accepts.
/// `set-client-info` accepts the identity fields so a mirror client can send
/// one shape to every daemon; dispatch ignores them (identity is the stamp).
pub(crate) const ALLOWED_COMMANDS: &[(&str, &[&str])] = &[
    ("identify", &[]),
    (
        "set-client-info",
        &[
            "name",
            "capabilities",
            "user_id",
            "display_name",
            "device_kind",
            "device_name",
            "device_id",
        ],
    ),
    ("subscribe", &[]),
    ("conversation-list", &[]),
    ("conversation-snapshot", &["conversation", "tail"]),
    ("conversation-history", &["conversation", "before_seq", "limit"]),
    ("conversation-op", &["conversation", "idempotency_key", "actor", "transaction", "op"]),
    ("conversation-typing", &["conversation", "actor", "on"]),
];

/// Section 4: the op kinds a remote peer may send, with their exact fields.
/// Approval kinds, `participants.*` and `title.set` are refused by name.
const ALLOWED_OPS: &[(&str, &[&str])] = &[
    ("message.send", &["client_msg_id", "parts", "reply_to"]),
    ("message.edit", &["message_id", "parts"]),
    ("message.retract", &["message_id"]),
    ("reaction.add", &["message_id", "part_index", "reaction"]),
    ("reaction.remove", &["message_id", "part_index", "reaction"]),
    ("read_cursor.set", &["seq"]),
];

const TEXT_PART_FIELDS: &[&str] = &["type", "text", "runs"];
const TEXT_RUN_FIELDS: &[&str] = &["start", "length", "mention", "link"];
const REPLY_TO_FIELDS: &[&str] = &["message_id", "part_index"];

/// Why a frame was refused. Internal only: the wire answer is always
/// `remote_denied` with no detail.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Denial {
    /// Not a JSON object (binary, malformed, an array, a scalar).
    NotAnObject,
    /// A resource-protocol frame (`protocol` member).
    ResourceProtocol,
    /// No `cmd` string.
    NoCommand,
    /// A command outside the allowlist (`loopback-*`, `scheduler.*`,
    /// `url-open`, every non-conversation command).
    Command,
    /// A command-bearing param.
    CommandParam,
    /// A param the command does not accept.
    UnknownParam,
    /// An id param that is not a plain id (ref form, prefix, name).
    IdShape,
    /// A capability outside [`REMOTE_CAPABILITIES`].
    Capability,
    /// An op kind outside the remote list, or a malformed op.
    OpKind,
    /// A part that is not a plain text part.
    Part,
}

/// Check one remote frame. `Ok` means the frame may be dispatched; the
/// conversation handlers still apply the owner scope.
pub(crate) fn check_frame(frame: &str) -> Result<(), Denial> {
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(frame) else {
        return Err(Denial::NotAnObject);
    };
    if object.contains_key("protocol") {
        return Err(Denial::ResourceProtocol);
    }
    let Some(Value::String(command)) = object.get("cmd") else {
        return Err(Denial::NoCommand);
    };
    let Some((_, params)) = ALLOWED_COMMANDS.iter().find(|(name, _)| *name == command) else {
        return Err(Denial::Command);
    };
    for key in object.keys() {
        if COMMAND_PARAMS.contains(&key.as_str()) {
            return Err(Denial::CommandParam);
        }
        if key != "id" && key != "cmd" && !params.contains(&key.as_str()) {
            return Err(Denial::UnknownParam);
        }
    }
    if let Some(conversation) = object.get("conversation") {
        check_id(conversation, "conv_")?;
    }
    if let Some(capabilities) = object.get("capabilities") {
        check_capabilities(capabilities)?;
    }
    match object.get("op") {
        Some(op) => check_op(op),
        None if command == "conversation-op" => Err(Denial::OpKind),
        None => Ok(()),
    }
}

/// A plain owner-made id: `prefix` then base-32 characters. Ref forms
/// (`@1`), names and bare prefixes are refused.
fn check_id(value: &Value, prefix: &str) -> Result<(), Denial> {
    let valid = value.as_str().and_then(|id| id.strip_prefix(prefix)).is_some_and(|rest| {
        !rest.is_empty() && rest.len() <= 64 && rest.bytes().all(|b| b.is_ascii_alphanumeric())
    });
    if valid { Ok(()) } else { Err(Denial::IdShape) }
}

fn check_capabilities(value: &Value) -> Result<(), Denial> {
    let valid = match value {
        Value::Null => true,
        Value::Array(items) => items.iter().all(|item| {
            item.as_str().is_some_and(|capability| REMOTE_CAPABILITIES.contains(&capability))
        }),
        _ => false,
    };
    if valid { Ok(()) } else { Err(Denial::Capability) }
}

fn check_fields(
    object: &Map<String, Value>,
    allowed: &[&str],
    denial: Denial,
) -> Result<(), Denial> {
    for key in object.keys() {
        if COMMAND_PARAMS.contains(&key.as_str()) {
            return Err(Denial::CommandParam);
        }
        if !allowed.contains(&key.as_str()) {
            return Err(denial);
        }
    }
    Ok(())
}

fn check_op(value: &Value) -> Result<(), Denial> {
    let Value::Object(op) = value else { return Err(Denial::OpKind) };
    let Some(Value::String(kind)) = op.get("kind") else { return Err(Denial::OpKind) };
    let Some((_, fields)) = ALLOWED_OPS.iter().find(|(name, _)| *name == kind) else {
        return Err(Denial::OpKind);
    };
    for key in op.keys().filter(|key| *key != "kind") {
        if COMMAND_PARAMS.contains(&key.as_str()) {
            return Err(Denial::CommandParam);
        }
        if !fields.contains(&key.as_str()) {
            return Err(Denial::UnknownParam);
        }
    }
    if let Some(message) = op.get("message_id") {
        check_id(message, "msg_")?;
    }
    if let Some(reply_to) = op.get("reply_to") {
        let Value::Object(reply_to) = reply_to else { return Err(Denial::UnknownParam) };
        check_fields(reply_to, REPLY_TO_FIELDS, Denial::UnknownParam)?;
        check_id(reply_to.get("message_id").unwrap_or(&Value::Null), "msg_")?;
    }
    match op.get("parts") {
        Some(Value::Array(parts)) => parts.iter().try_for_each(check_part),
        Some(_) => Err(Denial::Part),
        None => Ok(()),
    }
}

/// Only `{"type": "text", "text", "runs"}` parts. `work` parts and approval
/// parts are refused by name.
fn check_part(part: &Value) -> Result<(), Denial> {
    let Value::Object(part) = part else { return Err(Denial::Part) };
    if part.get("type").and_then(Value::as_str) != Some("text") {
        return Err(Denial::Part);
    }
    check_fields(part, TEXT_PART_FIELDS, Denial::Part)?;
    match part.get("runs") {
        None | Some(Value::Null) => Ok(()),
        Some(Value::Array(runs)) => runs.iter().try_for_each(|run| match run {
            Value::Object(run) => check_fields(run, TEXT_RUN_FIELDS, Denial::Part),
            _ => Err(Denial::Part),
        }),
        Some(_) => Err(Denial::Part),
    }
}

/// The conversation gate for `serve_remote_entry`: the section 4 allowlist
/// in place of the default `DenyAllGate`.
pub struct ConversationGate;

#[cfg(unix)]
impl super::super::RemoteGate for ConversationGate {
    fn admit(&self, _peer: &super::super::RemotePeer, frame: &str) -> bool {
        check_frame(frame).is_ok()
    }
}
