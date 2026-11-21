//! The public chat list and reversible, gesture-scoped marks. Reads use the watch-fed
//! index. Archive takes one explicit selection, shares one acpmux link, and reports each
//! accepted or failed target. Only accepted writes update the index ahead of its push.

use std::sync::Arc;

use crate::mux::chat_index::ChatTarget;
use serde_json::{Map, Value, json};

use super::{ParsedResourceRequest, ensure_session_route, mutation_result, required_string};
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    match request.envelope.operation {
        ResourceOperation::ChatList => {
            let include = request
                .fields
                .get("include_archived")
                .map(|v| {
                    v.as_bool().ok_or_else(|| {
                        ResourceError::validation_invalid(
                            Some("include_archived"),
                            "include_archived must be true or false",
                        )
                    })
                })
                .transpose()?
                .unwrap_or(false);
            Ok(Value::Array(mux.chat_rows(include)))
        }
        ResourceOperation::ChatArchive => archive(mux, &request.fields),
        ResourceOperation::ChatMarkRead => {
            let chat = mark_target(mux, &request.fields, request.envelope.operation.wire_name())?;
            mark(
                mux,
                "chat.mark_read",
                &chat,
                |mux| mux_mark_read(mux, &chat.route()),
                |row| {
                    row.insert("unread".into(), Value::Bool(false));
                    row.insert("unread_turns".into(), json!(0));
                },
            )
        }
        ResourceOperation::ChatPin => {
            let chat = mark_target(mux, &request.fields, request.envelope.operation.wire_name())?;
            let pinned =
                request.fields.get("pinned").and_then(Value::as_bool).ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("pinned"),
                        "pinned must be true or false",
                    )
                })?;
            mark(
                mux,
                "chat.pin",
                &chat,
                |mux| mux_pin(mux, &chat.route(), pinned),
                |row| {
                    row.insert("pinned".into(), Value::Bool(pinned));
                },
            )
        }
        other => Err(ResourceError::operation_failed(
            other.wire_name(),
            "the chat owner received an operation it does not own",
            json!({}),
        )),
    }
}

fn mark_target(
    mux: &Mux,
    fields: &Map<String, Value>,
    operation: &str,
) -> Result<ChatTarget, ResourceError> {
    let chat = required_string(fields, "chat")?;
    // Omitting the peer keeps the original local-first lookup. Explicit null selects local only.
    let target = match fields.get("peer") {
        None => mux.listed_chat(chat),
        Some(value) => {
            let peer: Option<String> = serde_json::from_value(value.clone()).map_err(|_| {
                ResourceError::validation_invalid(Some("peer"), "peer must be a string or null")
            })?;
            let target = ChatTarget { chat: chat.to_owned(), peer };
            mux.has_chat(&target, false).then_some(target)
        }
    };
    target.ok_or_else(|| {
        failed(operation, "not_found", format!("chat.list lists no matching chat {chat:?}"))
    })
}

/// Validate all input before writing, then report each explicit target independently.
fn archive(mux: &Mux, fields: &Map<String, Value>) -> Result<Value, ResourceError> {
    let archived = fields.get("archived").and_then(Value::as_bool).ok_or_else(|| {
        ResourceError::validation_invalid(Some("archived"), "archived must be true or false")
    })?;
    let targets: Vec<ChatTarget> = serde_json::from_value(
        fields.get("targets").cloned().unwrap_or(Value::Null),
    )
    .map_err(|error| ResourceError::validation_invalid(Some("targets"), error.to_string()))?;
    if targets.iter().any(|t| t.chat.is_empty() || t.peer.as_deref() == Some("")) {
        return Err(ResourceError::validation_invalid(
            Some("targets"),
            "chat and peer names must be nonempty",
        ));
    }
    #[cfg(unix)]
    let write = mux.acp_archive_writer().map_err(|err| {
        let (code, message) = reason(err);
        failed("chat.archive", code, message)
    })?;
    #[cfg(unix)]
    let write = |route: &str| write(route, archived).map_err(|err| reason(err).1);
    #[cfg(not(unix))]
    let write = |_: &str| Err(String::from("acpmux runs only on unix"));
    apply_archive(mux, &targets, archived, write)
}

fn apply_archive(
    mux: &Mux,
    targets: &[ChatTarget],
    archived: bool,
    mut write: impl FnMut(&str) -> Result<(), String>,
) -> Result<Value, ResourceError> {
    let mut outcomes = Vec::with_capacity(targets.len());
    for target in targets {
        let result = if mux.has_chat(target, true) {
            write(&target.route()).map(|()| mux.set_chat_archived(target, archived))
        } else {
            Err("chat.list lists no matching chat".to_owned())
        };
        outcomes.push(json!({"chat": target.chat, "peer": target.peer, "error": result.err()}));
    }
    mutation_result(mux, Value::Array(outcomes), mux.chat_revision(), false)
}

/// One chat mutation: the chat must be listed, acpmux must accept `call`, then
/// `apply` changes the row the answer carries.
fn mark(
    mux: &Arc<Mux>,
    operation: &'static str,
    chat: &ChatTarget,
    call: impl FnOnce(&Mux) -> Result<(), (&'static str, String)>,
    apply: impl FnOnce(&mut serde_json::Map<String, Value>),
) -> Result<Value, ResourceError> {
    call(mux).map_err(|(reason, message)| failed(operation, reason, message))?;
    let (row, revision) = mux.update_chat(chat, apply).ok_or_else(|| {
        failed(operation, "not_found", format!("chat {chat:?} left the list meanwhile"))
    })?;
    mutation_result(mux, row, revision, false)
}

fn failed(operation: &str, reason: &str, message: String) -> ResourceError {
    ResourceError::operation_failed(operation, reason, json!({"message": message}))
}

#[cfg(unix)]
fn reason(error: crate::server::ChatMarkError) -> (&'static str, String) {
    match error {
        crate::server::ChatMarkError::Unavailable(message) => ("unavailable", message),
        crate::server::ChatMarkError::Refused(message) => ("refused", message),
    }
}

#[cfg(unix)]
fn mux_mark_read(mux: &Mux, chat: &str) -> Result<(), (&'static str, String)> {
    mux.acp_chat_mark_read(chat).map_err(reason)
}

#[cfg(unix)]
fn mux_pin(mux: &Mux, chat: &str, pinned: bool) -> Result<(), (&'static str, String)> {
    mux.acp_chat_pin(chat, pinned).map_err(reason)
}

#[cfg(not(unix))]
fn mux_mark_read(_mux: &Mux, _chat: &str) -> Result<(), (&'static str, String)> {
    Err(("unavailable", "acpmux runs only on unix".into()))
}

#[cfg(not(unix))]
fn mux_pin(_mux: &Mux, _chat: &str, _pinned: bool) -> Result<(), (&'static str, String)> {
    Err(("unavailable", "acpmux runs only on unix".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batch_archive_keeps_peer_identity_and_reports_partial_success() {
        let mux = Mux::new_for_test("archive-chat-batch", crate::SurfaceOptions::default());
        let session = json!({"sessionId": "same", "lane": {"state": "idle"}, "spawnedBy": "root"});
        mux.change_chats(|chats| chats.page(std::slice::from_ref(&session)));
        mux.change_chats(|chats| {
            chats.push(&json!({"sessionId": "same", "peer": "west", "session": session}))
        });
        let local = ChatTarget { chat: "same".into(), peer: None };
        let peer = ChatTarget { chat: "same".into(), peer: Some("west".into()) };
        let gone = ChatTarget { chat: "gone".into(), peer: None };
        let targets = [local, peer.clone(), gone];
        let mut calls = Vec::new();
        let result = apply_archive(&mux, &targets, true, |route| {
            calls.push(route.to_owned());
            if route == "local/same" { Err("offline".to_owned()) } else { Ok(()) }
        })
        .unwrap();
        assert_eq!(calls, ["local/same", "west/same"]);
        assert_eq!(result["value"][0]["error"], "offline");
        assert!(result["value"][1]["error"].is_null());
        assert!(result["value"][2]["error"].is_string());
        let active = mux.chat_rows(false);
        assert_eq!(active.len(), 1);
        assert!(active[0]["machine"].is_null());
        assert_eq!(active[0]["parent"], "root");
        assert_eq!(mux.chat_rows(true).len(), 2);
        assert!(!mux.has_chat(&peer, false));
        apply_archive(&mux, &[peer], false, |_| Ok(())).unwrap();
        assert_eq!(mux.chat_rows(false).len(), 2);
    }
}
