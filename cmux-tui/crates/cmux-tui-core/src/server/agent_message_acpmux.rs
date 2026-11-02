//! The daemon's acpmux calls for agent messages (bead cx-55d27, PR 4): the
//! pump's hand-over of one queued message (`mux/agent_message_pump.rs`) and
//! the withdraw `agent.message.unsend` asks for. Each opens its own link to
//! this machine's acpmux socket, as the local unix-socket client acpmux
//! requires for `_acpmux/prompt_withdraw`, and never starts acpmux.

use crate::panic_free::JsonFields;
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

/// `_acpmux/info` for `session` without waiting for acpmux to read its chat logs
/// after a restart: these calls need only the session's id, which the session
/// list holds, and a large log store takes longer than [`INFO_TIMEOUT`].
pub(super) fn info_params(session: &str) -> Value {
    json!({"sessionId": session, "waitLogs": false})
}

/// What the hand-over hears first.
enum Heard {
    Accepted,
    Answered(Result<Value, LinkError>),
}

impl crate::mux::Mux {
    /// Hands `message` to the acpmux session `recipient` (`acp:<id>`) as a
    /// prompt whose id is the message id, with its provenance, steered into a
    /// running turn when its agent steers; delivered once
    /// acpmux accepts it (`_acpmux/prompt_accepted`) or answers its turn.
    pub(crate) fn acp_prompt_message(&self, message: &Value, recipient: &str) -> Handover {
        let (Some(session), Some(id)) =
            (recipient.strip_prefix("acp:"), message.field("id").as_str())
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
        let known = link.call("_acpmux/info", info_params(session), INFO_TIMEOUT);
        if !known.is_ok_and(|info| info.get("sessionId").and_then(Value::as_str) == Some(session)) {
            link.close();
            return Handover::Unreachable;
        }
        // Steered into a running turn when the agent steers, so a busy recipient reads it at its
        // next tool boundary instead of after its turn; acpmux queues it for an agent that does
        // not. A steer without `interrupt` never stops the turn; only an explicit interrupt
        // (`_meta.acpmux.interrupt`, or the queue's `interrupt` op, `queue_edit.rs`) does.
        let mut meta = json!({"steer": true, "promptId": id, "resend": true});
        if let Some(provenance) = provenance(message, recipient) {
            meta.insert("provenance", provenance);
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
            Ok(Heard::Answered(Err(
                LinkError::Rpc(message, _)
                | LinkError::MethodNotFound(message)
                | LinkError::BadList(message),
            ))) => Handover::Failed(message),
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
        let withdrawn = Self::withdraw_answer(answer);
        // acpmux answers a withdraw on its own daemon only, but forwards a
        // peer's session's `_acpmux/info` and prompts: a session it still
        // names may run the prompt, so only one it cannot name is gone.
        let withdrawn = match withdrawn {
            Ok(Withdrawn::NoSession) => {
                let info = link.call("_acpmux/info", info_params(session), INFO_TIMEOUT);
                match info {
                    Ok(info) if info.get("sessionId").and_then(Value::as_str) == Some(session) => {
                        Ok(Withdrawn::NotFound)
                    }
                    // acpmux names another session, or its own lookup
                    // (`Hub::resolve`) knows none here or on a peer.
                    Ok(_) => Ok(Withdrawn::NoSession),
                    Err(LinkError::Rpc(message, _))
                        if message.starts_with("no session matches") =>
                    {
                        Ok(Withdrawn::NoSession)
                    }
                    // A forward to a peer that failed, or no answer: the
                    // peer may hold the prompt.
                    Err(
                        LinkError::Rpc(..)
                        | LinkError::MethodNotFound(_)
                        | LinkError::Closed
                        | LinkError::Timeout
                        | LinkError::Busy
                        | LinkError::BadList(_),
                    ) => Err(WithdrawError::Unavailable),
                }
            }
            other => other,
        };
        link.close();
        withdrawn
    }

    /// acpmux's answer to `_acpmux/prompt_withdraw`.
    fn withdraw_answer(answer: Result<Value, LinkError>) -> Result<Withdrawn, WithdrawError> {
        match answer {
            Ok(reply) => match reply.get("outcome").and_then(Value::as_str) {
                Some("unsent") => Ok(Withdrawn::Unsent),
                Some("retracted") => Ok(Withdrawn::Retracted),
                Some("too_late") => Ok(Withdrawn::TooLate),
                _ => Err(WithdrawError::Refused("withdraw.unknown_outcome".to_owned())),
            },
            Err(LinkError::Rpc(message, data)) => withdraw_refusal(&message, &data),
            // An acpmux from before the method refuses it as any other error.
            Err(LinkError::MethodNotFound(message)) => withdraw_refusal(&message, &Value::Null),
            Err(
                LinkError::Closed | LinkError::Timeout | LinkError::Busy | LinkError::BadList(_),
            ) => Err(WithdrawError::Unavailable),
        }
    }
}

/// acpmux's error answer to `_acpmux/prompt_withdraw`: its message and its
/// `data`.
fn withdraw_refusal(message: &str, data: &Value) -> Result<Withdrawn, WithdrawError> {
    // acpmux names a refusal in `data.reason`, or before the first colon of
    // its message (`transfer.moving: …`); a blank one names none.
    let reason = data
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or_else(|| message.split(':').next().unwrap_or_default())
        .trim()
        .to_owned();
    if reason == "withdraw.not_found" {
        Ok(Withdrawn::NotFound)
    } else if message.starts_with("no session matches") {
        // acpmux's session lookup (`Hub::resolve`) names no reason; its
        // message is the stable part.
        Ok(Withdrawn::NoSession)
    } else if reason.is_empty() {
        Err(WithdrawError::Refused("withdraw.refused".to_owned()))
    } else {
        // The spec's limit on `error.acpmux_reason`.
        Err(WithdrawError::Refused(clip(&reason, ACPMUX_REASON_MAX)))
    }
}
