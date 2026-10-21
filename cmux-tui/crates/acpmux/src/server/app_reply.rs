//! The app pane's reply in place (IncomingMessageCard.tsx, direct.ts `reply`) goes out as a cmux
//! agent message, the way the replying chat's agent would send it with
//! `cmux agent message --reply-to`. The pane sends a `session/prompt` to the chat `to` that sent
//! the message, with an `agent_message` provenance; `Hub::app_reply_fits` (hub/withdraw.rs) has
//! already checked it: `from` is the chat this connection shows, by its exact id, and its log holds
//! the message `replyTo` names, which `to` sent it, in the thread `threadId` names. Then
//! [`send`] hands it to the cmux session daemon that `CMUX_TUI_SOCKET` names as
//! `agent.message.send` from that chat: under a launch credential minted for it
//! (`credential.mint {acp_session}`, as `launch_credential.rs` mints its agent's), with
//! `in_reply_to` the message, its thread and `to` as the one recipient, signed with the chat's own
//! name. The daemon checks it again (the parent exists, the chat takes part in its thread, the
//! limits), stores it under its own id and delivers it to `to` with its pump, as any agent message
//! (with the `Reply with` line). So `cmux agent message --reply-to`, `cmux agent message unsend`
//! and the inbox know it.
//!
//! It is never prompted here directly. Without a daemon it is refused
//! (`reply.daemon_unavailable`), and a daemon refusal is passed on (`reply.daemon_refused`).
//! Only `Origin::LocalApp` gets here: `prompt_provenance::of` refuses a provenance from Web and
//! Peer, and a unix-socket client sends its agent messages through the daemon itself.

use crate::rpc::RpcError;
use serde_json::{Value, json};

/// How long one daemon request waits: the send asks acpmux for the chats' workspaces first.
#[cfg(unix)]
const DAEMON_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

fn refusal(reason: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message.into()).with_data(json!({"reason": reason}))
}

fn unavailable() -> RpcError {
    refusal(
        "reply.daemon_unavailable",
        "a reply goes out as a cmux agent message, and no cmux session daemon took it",
    )
}

/// Sends the reply `provenance` (as `Hub::app_reply_fits` signed it) with the text of `blocks`
/// through the cmux session daemon; the `session/prompt` answer names the stored message.
/// `prompt_id` (the pane's `_meta.acpmux.promptId`) keys it, so a resend stores it once.
pub(super) async fn send(
    provenance: &Value,
    blocks: &[Value],
    prompt_id: Option<&str>,
) -> Result<Value, RpcError> {
    let field = |k: &str| provenance.get(k).and_then(Value::as_str).unwrap_or_default();
    let session = field("from").strip_prefix("acp:").unwrap_or_default().to_owned();
    let (to, reply_to, thread) = (field("to"), field("replyTo"), field("threadId"));
    if session.is_empty() || to.is_empty() || reply_to.is_empty() || thread.is_empty() {
        return Err(crate::prompt_provenance::origin_refused());
    }
    let Some(prompt_id) = prompt_id else {
        return Err(refusal("reply.prompt_id_required", "a reply needs _meta.acpmux.promptId"));
    };
    let mut texts = Vec::new();
    for block in blocks {
        match (block.get("type").and_then(Value::as_str), block.get("text").and_then(Value::as_str))
        {
            (Some("text"), Some(text)) => texts.push(text),
            _ => return Err(refusal("reply.text_only", "a reply is text only")),
        }
    }
    let body = texts.join("\n\n").trim().to_owned();
    if body.is_empty() {
        return Err(refusal("reply.text_only", "a reply needs text"));
    }
    let mut fields =
        json!({"recipients": [to], "body": body, "thread_id": thread, "in_reply_to": reply_to});
    if let Some(name) = provenance.get("fromName").and_then(Value::as_str) {
        fields["sender_name"] = json!(name);
    }
    let key = format!(
        "acpmux-reply-{}",
        crate::sha256::sha256_hex(format!("{session}\n{prompt_id}").as_bytes())
    );
    let socket = std::env::var_os(crate::launch_credential::SESSION_SOCKET_ENV)
        .filter(|s| !s.is_empty())
        .ok_or_else(unavailable)?;
    let sent = tokio::task::spawn_blocking(move || {
        daemon_send(std::path::Path::new(&socket), &session, fields, &key)
    })
    .await
    .map_err(|_| unavailable())??;
    let message = sent.get("value").cloned().unwrap_or(Value::Null);
    // The pane needs only that the daemon took it, and its id.
    Ok(json!({"stopReason": "end_turn", "_meta": {"acpmux": {"agentMessage": {
        "id": message.get("id"),
        "threadId": message.get("thread_id"),
    }}}}))
}

/// `agent.message.send` as the ACP session `session`, on one connection to `socket`.
#[cfg(unix)]
fn daemon_send(
    socket: &std::path::Path,
    session: &str,
    fields: Value,
    key: &str,
) -> Result<Value, RpcError> {
    let mut link = crate::launch_credential::DaemonLink::connect(socket, DAEMON_TIMEOUT)
        .ok_or_else(unavailable)?;
    let credential = link.mint(session).ok_or_else(unavailable)?;
    link.call("agent.message.send", fields, Some(&credential), Some(key)).map_err(|error| {
        if error.is_null() {
            return unavailable();
        }
        let said = error.get("message").and_then(Value::as_str).unwrap_or("refused");
        RpcError::invalid_params(format!("the cmux session daemon refused the reply: {said}"))
            .with_data(json!({
                "reason": "reply.daemon_refused",
                "code": error.get("code"),
                "daemonReason": error.pointer("/details/reason"),
            }))
    })
}

#[cfg(not(unix))]
fn daemon_send(
    _socket: &std::path::Path,
    _session: &str,
    _fields: Value,
    _key: &str,
) -> Result<Value, RpcError> {
    Err(unavailable())
}
