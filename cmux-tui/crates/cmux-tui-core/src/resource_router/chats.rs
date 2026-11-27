//! `chat.list`, `chat.mark_read` and `chat.pin` (plans/cmux-next/extensibility-DESIGN.md,
//! step 3): every ACP chat acpmux knows, for App Store apps, the CLI and the SDKs.
//!
//! `chat.list` reads the daemon's chat index (`mux/chat_index.rs`), which the
//! acpmux watch keeps; it calls nothing. The two mutations ask acpmux
//! (`server/chat_marks.rs`), which keeps the mark, then apply it to the index
//! so the answer and the next read agree; acpmux's push of the same change
//! finds the row already so and changes nothing more, so `chat.changed` fires
//! once. Both are naturally idempotent (marking read again, pinning again),
//! so a retried key does the same thing again harmlessly.

use std::sync::Arc;

use serde_json::{Value, json};

use super::{ParsedResourceRequest, ensure_session_route, mutation_result, required_string};
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    match request.envelope.operation {
        ResourceOperation::ChatList => Ok(Value::Array(mux.chat_rows())),
        ResourceOperation::ChatMarkRead => {
            let chat = required_string(&request.fields, "chat")?.to_owned();
            mark(
                mux,
                "chat.mark_read",
                &chat,
                |mux| mux_mark_read(mux, &chat),
                |row| {
                    row.insert("unread".into(), Value::Bool(false));
                    row.insert("unread_turns".into(), json!(0));
                },
            )
        }
        ResourceOperation::ChatPin => {
            let chat = required_string(&request.fields, "chat")?.to_owned();
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
                |mux| mux_pin(mux, &chat, pinned),
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

/// One chat mutation: the chat must be listed, acpmux must accept `call`, then
/// `apply` changes the row the answer carries.
fn mark(
    mux: &Arc<Mux>,
    operation: &'static str,
    chat: &str,
    call: impl FnOnce(&Mux) -> Result<(), (&'static str, String)>,
    apply: impl FnOnce(&mut serde_json::Map<String, Value>),
) -> Result<Value, ResourceError> {
    if !mux.chat_listed(chat) {
        return Err(failed(operation, "not_found", format!("chat.list lists no chat {chat:?}")));
    }
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
