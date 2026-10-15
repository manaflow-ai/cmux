//! The daemon's agent message delivery pump (bead cx-55d27, PR 4). A queued
//! delivery to an acpmux session (`acp:<id>`) goes to that session as a
//! prompt whose id is the message id and whose `_meta.acpmux.provenance`
//! names the sender (`agent_message_prompt.rs`); acpmux runs a prompt id
//! once, so a resend never runs it twice. Each outcome is recorded through `agent.message.mark`'s path (`delivered` via
//! `acp.prompt`, or `failed` with acpmux's error), one attempt each.
//!
//! The pump wakes on a send or a release that queues a delivery, the
//! daemon's start (deliveries a restart left queued), and each time the
//! agent chat watch reconnects to acpmux. While a delivery waits (acpmux is
//! down, runs no such session yet, moves it, or never accepted the prompt),
//! a backoff timer wakes it too, from [`RETRY_FIRST`] up to [`RETRY_MAX`];
//! a pass that leaves nothing waiting disarms it. A prompt acpmux never
//! accepted stays queued with the attempt counted: acpmux may still run it,
//! so an unsend asks acpmux about it. A held delivery is never touched (only
//! `agent.message.release` queues it). Each pass reads the queued acpmux
//! deliveries only, a page at a time, so queued terminal messages never
//! hide one. One delivery at a time is handed over and recorded under the
//! delivery lock, which `agent.message.unsend` takes too, so an unsend never
//! races a hand-over; the daemon is the one acpmux delivery path (the CLI
//! waits for the pump).
// Off unix nothing starts the pump (no acpmux), and nothing is handed over.
#![cfg_attr(not(unix), allow(dead_code))]

use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use super::Mux;
use crate::state::agent_message_store as messages;
use crate::state::commit::StateEffects;
use crate::state::store::StateChanges;

/// Queued acpmux deliveries one read takes, oldest first.
const PAGE: usize = 200;
/// The first retry of a waiting delivery, doubled each pass up to [`RETRY_MAX`].
const RETRY_FIRST: Duration = Duration::from_secs(1);
const RETRY_MAX: Duration = Duration::from_secs(60);
const ORIGIN: &str = "agent-message-pump";

/// The pump's wake and the delivery lock.
#[derive(Default)]
pub(crate) struct AgentMessagePump {
    wake: Mutex<Option<SyncSender<()>>>,
    delivering: Mutex<()>,
}

/// How one hand-over to acpmux went.
pub(crate) enum Handover {
    Delivered,
    /// acpmux refused the prompt: its error.
    Failed(String),
    /// acpmux is down, runs no such session or moves it: nothing went out.
    Unreachable,
    /// The prompt went out and acpmux never accepted it: why.
    Unsettled(String),
}

/// What one delivery's turn in a pass left.
#[derive(PartialEq, Eq)]
enum Pumped {
    Done,
    /// It waits for the retry timer.
    Waits,
    /// acpmux cannot take anything for this recipient this pass.
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

    /// One pass over every queued acpmux delivery, oldest first; whether
    /// one still waits.
    fn pump_agent_messages(&self) -> bool {
        let session_id = self.session_public_id.as_str().to_owned();
        let mut cursor = (i64::MIN, i64::MIN);
        let mut unreachable: Vec<String> = Vec::new();
        let mut waits = false;
        loop {
            let Ok(page) = self.read_registry_state(|connection| queued_acp(connection, cursor))
            else {
                self.report_internal_diagnostic("agent message pump could not read the queue");
                return true;
            };
            let more = page.len() == PAGE;
            for (sequence, position, id, recipient) in page {
                cursor = (sequence, position);
                if unreachable.contains(&recipient) {
                    continue;
                }
                match self.pump_one(&session_id, &id, &recipient) {
                    Pumped::Done => {}
                    Pumped::Waits => waits = true,
                    Pumped::Unreachable => unreachable.push(recipient),
                }
            }
            if !more {
                return waits || !unreachable.is_empty();
            }
        }
    }

    /// Hands `id` to `recipient` if it is still queued and records the
    /// outcome.
    fn pump_one(&self, session_id: &str, id: &str, recipient: &str) -> Pumped {
        let _delivering = self.agent_message_delivery_lock();
        let now = crate::state::agent_message_policy::now_ms();
        let Ok(Some(message)) = self
            .read_registry_state(|connection| messages::snapshot(connection, session_id, id, now))
        else {
            return Pumped::Done;
        };
        let queued =
            message["deliveries"].as_array().into_iter().flatten().any(|delivery| {
                delivery["recipient"] == recipient && delivery["state"] == "queued"
            });
        if !queued {
            return Pumped::Done;
        }
        let (state, error) = match self.acp_prompt_message(&message, recipient) {
            Handover::Delivered => ("delivered", None),
            Handover::Failed(error) => ("failed", Some(truncate(&error, 1024))),
            Handover::Unreachable => return Pumped::Unreachable,
            Handover::Unsettled(error) => {
                if self.note_agent_message_attempt(id, recipient, &error).is_err() {
                    self.report_internal_diagnostic("agent message pump could not note an attempt");
                }
                return Pumped::Waits;
            }
        };
        let marked = self.agent_message_mark(
            &crate::WorkspaceMutation::daemon_local(ORIGIN),
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
        Pumped::Done
    }

    /// Counts a hand-over acpmux never accepted on a delivery that stays
    /// queued, with why.
    fn note_agent_message_attempt(
        &self,
        id: &str,
        recipient: &str,
        error: &str,
    ) -> anyhow::Result<()> {
        let error = truncate(error, 1024);
        let fingerprint = json!({"operation": "agent.message.attempt", "id": id,
            "recipient": recipient, "error": error});
        self.commit_state(
            &crate::WorkspaceMutation::daemon_local(ORIGIN),
            "agent.message.attempt",
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                transaction.execute(
                    "UPDATE agent_message_deliveries
                     SET attempts = attempts + 1, error = ?3, updated_at_ms = ?4,
                         via = 'acp.prompt'
                     WHERE message_id = ?1 AND recipient = ?2 AND state = 'queued'",
                    params![id, recipient, error, crate::state::agent_message_policy::now_ms()],
                )?;
                Ok(StateChanges::new(Value::Null, Vec::new()))
            },
        )
        .map(|_| ())
    }
}

/// Up to [`PAGE`] queued acpmux deliveries after `cursor` (a message's
/// sequence and the delivery's position), oldest first:
/// `(sequence, position, message id, recipient)`.
fn queued_acp(
    connection: &Connection,
    cursor: (i64, i64),
) -> anyhow::Result<Vec<(i64, i64, String, String)>> {
    let mut statement = connection.prepare(
        "SELECT m.sequence, d.position, m.message_id, d.recipient
         FROM agent_message_deliveries AS d
         JOIN agent_messages AS m ON m.message_id = d.message_id
         WHERE d.state = 'queued' AND d.recipient LIKE 'acp:%'
           AND (m.sequence > ?1 OR (m.sequence = ?1 AND d.position > ?2))
         ORDER BY m.sequence, d.position
         LIMIT ?3",
    )?;
    let rows = statement
        .query_map(params![cursor.0, cursor.1, i64::try_from(PAGE)?], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Waits for wakes, and while a delivery waits for the retry timer, until
/// the daemon ends.
fn run(mux: &Weak<Mux>, woken: &Receiver<()>) {
    let mut retry: Option<Duration> = None;
    loop {
        let woke = match retry {
            None => woken.recv().is_ok(),
            Some(delay) => {
                !matches!(woken.recv_timeout(delay), Err(RecvTimeoutError::Disconnected))
            }
        };
        if !woke {
            return;
        }
        let Some(mux) = mux.upgrade() else { return };
        if mux.shutting_down.load(std::sync::atomic::Ordering::Acquire) {
            return;
        }
        retry = mux
            .pump_agent_messages()
            .then(|| retry.map_or(RETRY_FIRST, |delay| (delay * 2).min(RETRY_MAX)));
    }
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
