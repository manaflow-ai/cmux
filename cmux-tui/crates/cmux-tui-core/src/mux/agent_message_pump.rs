//! The daemon's agent message delivery pump (bead cx-55d27, PR 4). A queued
//! delivery to an acpmux session (`acp:<id>`) goes to that session as a
//! prompt whose id is the message id and whose `_meta.acpmux.provenance`
//! names the sender (`agent_message_prompt.rs`, the same prompt the CLI's own
//! delivery builds); acpmux runs a prompt id once, so the pump and the CLI
//! may both hand a message over without it running twice. Each outcome is
//! recorded through `agent.message.mark`'s path (`delivered` via
//! `acp.prompt`, or `failed` with acpmux's error), one attempt each.
//!
//! The pump waits for a wake, never on a timer: a send or a release that
//! queues a delivery, the daemon's start (deliveries a restart left queued),
//! and each time the agent chat watch reconnects to acpmux (deliveries that
//! waited for acpmux to come back). A delivery whose session acpmux does not
//! run, or that waits while acpmux is down, stays queued for the next wake;
//! a held delivery is never touched (only `agent.message.release` queues
//! it). One delivery at a time is handed over and recorded under the
//! delivery lock, which `agent.message.unsend` takes too, so an unsend never
//! races a hand-over.
// Off unix nothing starts the pump (no acpmux), and nothing is handed over.
#![cfg_attr(not(unix), allow(dead_code))]

use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, MutexGuard, Weak};

use serde_json::Value;

use super::Mux;
use crate::state::agent_message_store::{self as messages, AgentMessageFilter};

/// Queued messages one pass reads, oldest first.
const PASS_LIMIT: usize = 200;

/// The pump's wake and the delivery lock.
#[derive(Default)]
pub(crate) struct AgentMessagePump {
    wake: Mutex<Option<SyncSender<()>>>,
    delivering: Mutex<()>,
}

/// How one hand-over to acpmux went.
pub(crate) enum Handover {
    Delivered,
    /// acpmux refused the prompt or never accepted it: its error.
    Failed(String),
    /// acpmux is down or runs no such session: the delivery stays queued.
    Unreachable,
}

impl Mux {
    /// Starts the pump thread (once) and wakes it for what a restart left
    /// queued.
    pub(crate) fn start_agent_message_pump(self: &Arc<Self>) {
        let (wake, woken) = sync_channel(1);
        {
            let mut slot = self.agent_message_pump.wake.lock().unwrap_or_else(|e| e.into_inner());
            if slot.is_some() {
                return;
            }
            *slot = Some(wake);
        }
        let mux = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name("mux-agent-message-pump".into())
            .stack_size(256 * 1024)
            .spawn(move || run(&mux, &woken));
        if spawned.is_err() {
            self.report_internal_diagnostic("agent message pump not started");
            return;
        }
        self.wake_agent_message_pump();
    }

    /// Asks the pump for another pass; wakes that arrive during one fold
    /// into the next.
    pub(crate) fn wake_agent_message_pump(&self) {
        if let Some(wake) = &*self.agent_message_pump.wake.lock().unwrap_or_else(|e| e.into_inner())
        {
            let _ = wake.try_send(());
        }
    }

    /// Held while a delivery is handed over and recorded, and while an
    /// unsend decides.
    pub(crate) fn agent_message_delivery_lock(&self) -> MutexGuard<'_, ()> {
        self.agent_message_pump.delivering.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// One pass: every queued acpmux delivery, oldest first.
    fn pump_agent_messages(&self) {
        let session_id = self.session_public_id.as_str().to_owned();
        let filter = AgentMessageFilter {
            state: Some("queued".to_owned()),
            oldest_first: true,
            ..AgentMessageFilter::default()
        };
        let now = crate::state::agent_message_policy::now_ms();
        let Ok(queued) = self.read_registry_state(|connection| {
            messages::list(connection, &session_id, &filter, PASS_LIMIT, now)
        }) else {
            self.report_internal_diagnostic("agent message pump could not read the queue");
            return;
        };
        let mut unreachable: Vec<String> = Vec::new();
        for message in queued {
            let Some(id) = message["id"].as_str() else { continue };
            for recipient in queued_acp_recipients(&message) {
                if unreachable.contains(&recipient) {
                    continue;
                }
                if !self.pump_one(&session_id, id, &recipient) {
                    unreachable.push(recipient);
                }
            }
        }
    }

    /// Hands `id` to `recipient` if it is still queued and records the
    /// outcome; false when acpmux could not be reached for it.
    fn pump_one(&self, session_id: &str, id: &str, recipient: &str) -> bool {
        let _delivering = self.agent_message_delivery_lock();
        let now = crate::state::agent_message_policy::now_ms();
        let Ok(Some(message)) = self
            .read_registry_state(|connection| messages::snapshot(connection, session_id, id, now))
        else {
            return true;
        };
        if !queued_acp_recipients(&message).iter().any(|queued| queued == recipient) {
            return true;
        }
        let (state, error) = match self.acp_prompt_message(&message, recipient) {
            Handover::Delivered => ("delivered", None),
            Handover::Failed(error) => ("failed", Some(truncate(&error, 1024))),
            Handover::Unreachable => return false,
        };
        let mutation = crate::WorkspaceMutation::daemon_local("agent-message-pump");
        let marked = self.agent_message_mark(
            &mutation,
            None,
            &Mux::ordinary_resource_selectors(),
            &[id.to_owned()],
            recipient,
            state,
            Some("acp.prompt"),
            error.as_deref(),
        );
        if marked.is_err() {
            self.report_internal_diagnostic("agent message pump could not record a delivery");
        }
        true
    }
}

/// Waits for wakes until the daemon ends.
fn run(mux: &Weak<Mux>, woken: &Receiver<()>) {
    while woken.recv().is_ok() {
        let Some(mux) = mux.upgrade() else { return };
        if mux.shutting_down.load(std::sync::atomic::Ordering::Acquire) {
            return;
        }
        mux.pump_agent_messages();
    }
}

/// The acpmux recipients of `message` whose delivery is queued.
fn queued_acp_recipients(message: &Value) -> Vec<String> {
    message["deliveries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|delivery| delivery["state"] == "queued")
        .filter_map(|delivery| delivery["recipient"].as_str())
        .filter(|recipient| recipient.starts_with("acp:"))
        .map(str::to_owned)
        .collect()
}

fn truncate(text: &str, max_bytes: usize) -> String {
    let mut end = text.len().min(max_bytes);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}

/// No acpmux off unix: nothing is handed over and nothing withdrawn.
#[cfg(not(unix))]
impl Mux {
    pub(crate) fn acp_prompt_message(&self, _message: &Value, _recipient: &str) -> Handover {
        Handover::Unreachable
    }

    pub(crate) fn acp_withdraw_message(
        &self,
        _session: &str,
        _message_id: &str,
    ) -> Result<
        crate::state::agent_message_unsend::Withdrawn,
        crate::state::agent_message_unsend::WithdrawError,
    > {
        Err(crate::state::agent_message_unsend::WithdrawError::Unavailable)
    }
}
