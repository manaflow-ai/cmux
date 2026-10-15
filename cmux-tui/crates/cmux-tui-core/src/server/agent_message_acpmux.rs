//! The daemon's acpmux calls for agent messages (bead cx-55d27, PR 4): the
//! pump's hand-over of one queued message (`mux/agent_message_pump.rs`) and
//! the withdraw `agent.message.unsend` asks for. Each opens its own link to
//! this machine's acpmux socket, as the local unix-socket client acpmux
//! requires for `_acpmux/prompt_withdraw`, and never starts acpmux.

use std::sync::mpsc::sync_channel;
use std::time::Duration;

use serde_json::{Value, json};

use super::{AcpmuxLink, Inbound, LinkError};
use crate::agent_message_prompt::{provenance, render};
use crate::mux::agent_message_pump::Handover;
use crate::state::agent_message_unsend::{WithdrawError, Withdrawn, clip};

/// How long a hand-over waits for acpmux to name the session.
const INFO_TIMEOUT: Duration = Duration::from_secs(2);
/// How long it waits for acpmux to accept the prompt (queued or started).
const ACCEPT_TIMEOUT: Duration = Duration::from_secs(10);
/// How long a withdraw waits; acpmux waits up to 5 s for its notice.
const WITHDRAW_TIMEOUT: Duration = Duration::from_secs(10);
const PROMPT_THREAD_STACK_BYTES: usize = 256 * 1024;
/// The spec's limit on an unsend's `error.acpmux_reason`, in UTF-8 bytes.
const ACPMUX_REASON_MAX: usize = 128;

/// What the hand-over hears first.
enum Heard {
    Accepted,
    Answered(Result<Value, LinkError>),
}

impl crate::mux::Mux {
    /// Hands `message` to the acpmux session `recipient` (`acp:<id>`) as a
    /// prompt whose id is the message id, with its provenance; delivered once
    /// acpmux accepts it (`_acpmux/prompt_accepted`) or answers its turn.
    pub(crate) fn acp_prompt_message(&self, message: &Value, recipient: &str) -> Handover {
        let (Some(session), Some(id)) = (recipient.strip_prefix("acp:"), message["id"].as_str())
        else {
            return Handover::Unreachable;
        };
        let Some(socket) = self.control_clients.agent_sessions.socket() else {
            return Handover::Unreachable;
        };
        let (heard, hearing) = sync_channel::<Heard>(4);
        let accepted = heard.clone();
        let prompt_id = id.to_owned();
        let Ok(link) = AcpmuxLink::connect(&socket, move |inbound| {
            if let Inbound::Notification(method, params) = inbound
                && method == "_acpmux/prompt_accepted"
                && params.get("promptId").and_then(Value::as_str) == Some(prompt_id.as_str())
            {
                let _ = accepted.try_send(Heard::Accepted);
            }
        }) else {
            return Handover::Unreachable;
        };
        // Only a session acpmux runs, by its exact id, takes the prompt.
        let known = link.call("_acpmux/info", json!({"sessionId": session}), INFO_TIMEOUT);
        if !known.is_ok_and(|info| info.get("sessionId").and_then(Value::as_str) == Some(session)) {
            link.close();
            return Handover::Unreachable;
        }
        let mut meta = json!({"steer": false, "promptId": id, "resend": true});
        if let Some(provenance) = provenance(message, recipient) {
            meta["provenance"] = provenance;
        }
        let text = render(std::slice::from_ref(message));
        let params = json!({
            "sessionId": session,
            "prompt": [{"type": "text", "text": text}],
            "_meta": {"acpmux": meta},
        });
        // The turn's own answer comes when it ends; the link closes first.
        let caller = link.clone();
        let spawned = std::thread::Builder::new()
            .name("mux-agent-message-prompt".into())
            .stack_size(PROMPT_THREAD_STACK_BYTES)
            .spawn(move || {
                let answer = caller.call("session/prompt", params, ACCEPT_TIMEOUT);
                let _ = heard.try_send(Heard::Answered(answer));
            });
        if spawned.is_err() {
            link.close();
            return Handover::Unreachable;
        }
        let handover = match hearing.recv_timeout(ACCEPT_TIMEOUT) {
            Ok(Heard::Accepted | Heard::Answered(Ok(_))) => Handover::Delivered,
            // A session moving to another machine takes prompts again later.
            Ok(Heard::Answered(Err(LinkError::Rpc(message, data))))
                if message.starts_with("transfer.")
                    || data
                        .get("reason")
                        .and_then(Value::as_str)
                        .is_some_and(|reason| reason.starts_with("transfer.")) =>
            {
                Handover::Unreachable
            }
            Ok(Heard::Answered(Err(LinkError::Rpc(message, _)))) => Handover::Failed(message),
            // The prompt went out and no answer came: acpmux may run it, and
            // a resend under the same id runs it once.
            Ok(Heard::Answered(Err(LinkError::Closed))) => {
                Handover::Unsettled("acpmux closed the link before accepting the prompt".into())
            }
            Ok(Heard::Answered(Err(LinkError::Timeout | LinkError::Busy))) | Err(_) => {
                Handover::Unsettled("acpmux did not accept the prompt in time".into())
            }
        };
        link.close();
        handover
    }

    /// `_acpmux/prompt_withdraw {sessionId, msgId}` on `session`: acpmux's
    /// outcome, or why there is none.
    pub(crate) fn acp_withdraw_message(
        &self,
        session: &str,
        message_id: &str,
    ) -> Result<Withdrawn, WithdrawError> {
        let socket =
            self.control_clients.agent_sessions.socket().ok_or(WithdrawError::Unavailable)?;
        let link = AcpmuxLink::connect(&socket, |_| {}).map_err(|_| WithdrawError::Unavailable)?;
        let answer = link.call(
            "_acpmux/prompt_withdraw",
            json!({"sessionId": session, "msgId": message_id}),
            WITHDRAW_TIMEOUT,
        );
        link.close();
        match answer {
            Ok(reply) => match reply.get("outcome").and_then(Value::as_str) {
                Some("unsent") => Ok(Withdrawn::Unsent),
                Some("retracted") => Ok(Withdrawn::Retracted),
                Some("too_late") => Ok(Withdrawn::TooLate),
                _ => Err(WithdrawError::Refused("withdraw.unknown_outcome".to_owned())),
            },
            Err(LinkError::Rpc(message, data)) => {
                // acpmux names a refusal in `data.reason`, or before the
                // first colon of its message (`transfer.moving: …`).
                let reason = data.get("reason").and_then(Value::as_str).map_or_else(
                    || message.split(':').next().unwrap_or_default().trim().to_owned(),
                    str::to_owned,
                );
                if reason == "withdraw.not_found" || message.starts_with("no session matches") {
                    Ok(Withdrawn::NotFound)
                } else if reason.is_empty() {
                    Err(WithdrawError::Refused("withdraw.refused".to_owned()))
                } else {
                    // The spec's limit on `error.acpmux_reason`.
                    Err(WithdrawError::Refused(clip(&reason, ACPMUX_REASON_MAX)))
                }
            }
            Err(LinkError::Closed | LinkError::Timeout | LinkError::Busy) => {
                Err(WithdrawError::Unavailable)
            }
        }
    }
}
