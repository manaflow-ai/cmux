//! `_acpmux/app_reply {sessionId, to, replyTo, threadId, text, replyId}`: the app pane's reply in
//! place (IncomingMessageCard.tsx, direct.ts `reply`) to an agent message, checked, signed and
//! answered, never prompted. Chat `sessionId` answers message `replyTo` of thread `threadId`,
//! which chat `to` sent it. `Hub::app_reply_fits` (hub/withdraw.rs) checks that `sessionId` is a
//! chat here, by its exact id, that this connection shows (attached and not held unseen), and
//! that its log holds that message from `to` in that thread. The answer is the reply as acpmux
//! signs it: the chats' `acp:<id>` addresses, the chat's own name (`fromName`, never the pane's),
//! the text and an idempotency key from the chat and `replyId`.
//!
//! The app's pane host sends it on (CmuxNextAgentPane `AgentPaneAgentReply.swift`): the one
//! connection that may mint a launch credential (cmux-tui-core `check_credential_owner`) mints one
//! for the chat and sends `agent.message.send {in_reply_to, thread_id, body, sender_name}` as that
//! chat. The cmux session daemon checks it again (the parent exists, the chat takes part in its
//! thread, the limits), stores it under its own id and delivers it to `to` with its pump, as any
//! agent message (with the `Reply with` line), so `cmux agent message --reply-to`, `unsend` and
//! the inbox know it.
//!
//! Only `Origin::LocalApp`: a unix-socket client is an agent or the CLI, which sends its own
//! messages through the daemon, and a remote browser or a peer never answers as a chat here. The
//! method is never forwarded to a peer (`peer_forward.rs`). A `session/prompt` provenance from the
//! app is refused (`remote_guard.rs`): a reply never reaches the other chat behind the store.

use super::{Conn, Origin};
use crate::hub::Hub;
use crate::rpc::RpcError;
use serde_json::{Value, json};

/// Longest reply text, in bytes: the daemon's body limit (cmux-tui-core `MAX_BODY_BYTES`).
const MAX_TEXT_BYTES: usize = 32 * 1024;

fn refusal(reason: &str, message: &str) -> RpcError {
    RpcError::invalid_params(message.to_owned()).with_data(json!({"reason": reason}))
}

fn refused() -> RpcError {
    refusal(
        "reply.refused",
        "a reply in place answers a message the chat this pane shows got from the chat it names",
    )
}

/// The reply in `params` as acpmux checked and signed it (see the module docs).
pub(super) fn check(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if conn.origin != Origin::LocalApp {
        return Err(refusal(
            "reply.origin_refused",
            "a reply in place is accepted only from the cmux app's own pane",
        ));
    }
    let field = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or_default();
    let (from, to, reply_id) = (field("sessionId"), field("to"), field("replyId"));
    let text = field("text").trim();
    // The fields as a provenance, each one line that `prompt_provenance::of` takes.
    let provenance = json!({"kind": "agent_message", "from": format!("acp:{from}"),
        "to": format!("acp:{to}"), "msgId": reply_id, "threadId": field("threadId"),
        "replyTo": field("replyTo")});
    let wrapped = json!({"_meta": {"acpmux": {"provenance": provenance}}});
    let Ok(Some(provenance)) =
        crate::prompt_provenance::of(&wrapped, crate::prompt_provenance::Sender::Local)
    else {
        return Err(refused());
    };
    if field("replyTo").is_empty() {
        return Err(refused());
    }
    let shows = |id: &str| conn.sub_opts(id).is_some_and(|o| !o.hidden);
    let signed = hub.app_reply_fits(&provenance, to, &shows).ok_or_else(refused)?;
    // The daemon's body rule (`validate_body`): no control character but newlines and tabs.
    let control = text.chars().any(|c| c.is_control() && c != '\n' && c != '\t');
    if text.is_empty() || text.len() > MAX_TEXT_BYTES || control {
        return Err(refusal(
            "reply.text_required",
            &format!(
                "a reply is 1 to {MAX_TEXT_BYTES} bytes of text, no controls but newlines and tabs"
            ),
        ));
    }
    let key = format!(
        "acpmux-reply-{}",
        crate::sha256::sha256_hex(format!("{from}\n{reply_id}").as_bytes())
    );
    Ok(json!({"reply": {
        "from": signed["from"],
        "fromName": signed.get("fromName"),
        "to": signed["to"],
        "replyTo": signed["replyTo"],
        "threadId": signed["threadId"],
        "text": text,
        "idempotencyKey": key,
    }}))
}
