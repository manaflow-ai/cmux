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
//! hide one. Each recipient has at most one hand-over out, on its own
//! thread, so a session acpmux is slow to take (its chat logs still load)
//! holds up no other session's message. A hand-over is claimed, and its
//! outcome recorded, under the delivery lock, which `agent.message.unsend`
//! takes too; the acpmux call itself runs outside it, and an unsend counts
//! a hand-over that is out as tried, so it asks acpmux instead of taking
//! the message back alone. The daemon is the one acpmux delivery path (the
//! CLI waits for the pump).
// Off unix nothing starts the pump (no acpmux), and nothing is handed over.
#![cfg_attr(not(unix), allow(dead_code))]

use std::collections::{HashMap, HashSet};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use super::Mux;
use crate::state::agent_message_store as messages;
use crate::state::agent_message_unsend::clip;
use crate::state::commit::StateEffects;
use crate::state::store::StateChanges;

/// Queued acpmux deliveries one read takes, oldest first.
const PAGE: usize = 200;
/// The first retry of a waiting delivery, doubled each pass up to [`RETRY_MAX`].
const RETRY_FIRST: Duration = Duration::from_secs(1);
const RETRY_MAX: Duration = Duration::from_secs(60);
const ORIGIN: &str = "agent-message-pump";
/// The limit on a delivery's stored `error`, in UTF-8 bytes.
const ERROR_MAX: usize = 1024;
/// The most hand-overs out at once; more recipients wait for a later pass.
const IN_FLIGHT_MAX: usize = 16;
const HANDOVER_THREAD_STACK_BYTES: usize = 256 * 1024;

/// The pump's wake and the delivery lock.
#[derive(Default)]
pub(crate) struct AgentMessagePump {
    wake: Mutex<Option<SyncSender<()>>>,
    delivering: Mutex<()>,
    /// `(message id, recipient)` of hand-overs that went out unaccepted
    /// whose attempt could not be noted: an unsend treats them as tried.
    unnoted: Mutex<HashSet<(String, String)>>,
    /// Recipient -> the message whose hand-over to it is out. Changed only
    /// under the delivery lock; an unsend treats it as tried.
    in_flight: Mutex<HashMap<String, String>>,
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

    /// Held while a hand-over is claimed and while its outcome is recorded
    /// (not while acpmux is asked), and while an unsend decides.
    pub(crate) fn agent_message_delivery_lock(&self) -> MutexGuard<'_, ()> {
        self.agent_message_pump.delivering.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Whether a hand-over of `id` to `recipient` is out now, or went out
    /// unaccepted and its attempt could not be noted.
    pub(crate) fn agent_message_attempt_unnoted(&self, id: &str, recipient: &str) -> bool {
        let out = self.in_flight().get(recipient).is_some_and(|out| out == id);
        let unnoted = self.agent_message_pump.unnoted.lock().unwrap_or_else(|e| e.into_inner());
        out || unnoted.contains(&(id.to_owned(), recipient.to_owned()))
    }

    fn in_flight(&self) -> MutexGuard<'_, HashMap<String, String>> {
        self.agent_message_pump.in_flight.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// One pass over every queued acpmux delivery, oldest first; whether
    /// one still waits. A recipient one waits for (its hand-over is out),
    /// or acpmux cannot reach, gets nothing more this pass: its later
    /// messages never overtake it. The pass never waits for acpmux itself.
    fn pump_agent_messages(self: &Arc<Self>) -> bool {
        let session_id = self.session_public_id.as_str().to_owned();
        let mut cursor = (i64::MIN, i64::MIN);
        let mut skipped: Vec<String> = Vec::new();
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
                if skipped.contains(&recipient) {
                    continue;
                }
                match self.pump_one(&session_id, &id, &recipient) {
                    Pumped::Done => {}
                    Pumped::Waits => {
                        waits = true;
                        skipped.push(recipient);
                    }
                    Pumped::Unreachable => skipped.push(recipient),
                }
            }
            if !more {
                return waits || !skipped.is_empty();
            }
        }
    }

    /// Claims `id`'s hand-over to `recipient` if it is still queued and no
    /// hand-over to `recipient` is out, and starts it on its own thread,
    /// which records the outcome. The recipient waits for it this pass.
    fn pump_one(self: &Arc<Self>, session_id: &str, id: &str, recipient: &str) -> Pumped {
        let message = {
            let _delivering = self.agent_message_delivery_lock();
            let mut in_flight = self.in_flight();
            if in_flight.contains_key(recipient) || in_flight.len() >= IN_FLIGHT_MAX {
                return Pumped::Waits;
            }
            let Ok(Some(message)) = self.queued_message(session_id, id, recipient) else {
                return Pumped::Done;
            };
            in_flight.insert(recipient.to_owned(), id.to_owned());
            message
        };
        let mux = Arc::clone(self);
        let (session_id, id_owned, recipient_owned) =
            (session_id.to_owned(), id.to_owned(), recipient.to_owned());
        let spawned = std::thread::Builder::new()
            .name("mux-agent-message-handover".into())
            .stack_size(HANDOVER_THREAD_STACK_BYTES)
            .spawn(move || mux.hand_over(&session_id, &message, &id_owned, &recipient_owned));
        if spawned.is_err() {
            // Nothing went out: the delivery stays queued for a later pass.
            let _delivering = self.agent_message_delivery_lock();
            self.in_flight().remove(recipient);
            self.report_internal_diagnostic("agent message pump could not start a hand-over");
            return Pumped::Unreachable;
        }
        Pumped::Waits
    }

    /// `id`'s snapshot if its delivery to `recipient` is still queued.
    fn queued_message(
        &self,
        session_id: &str,
        id: &str,
        recipient: &str,
    ) -> anyhow::Result<Option<Value>> {
        let now = crate::state::agent_message_policy::now_ms();
        let message = self.read_registry_state(|connection| {
            messages::snapshot(connection, session_id, id, now)
        })?;
        Ok(message.filter(|message| {
            message["deliveries"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|delivery| delivery["recipient"] == recipient && delivery["state"] == "queued")
        }))
    }

    /// One claimed hand-over, outside the delivery lock, then its outcome
    /// under it; wakes the pump for the recipient's next message once done.
    fn hand_over(&self, session_id: &str, message: &Value, id: &str, recipient: &str) {
        let handover = self.acp_prompt_message(message, recipient);
        let pumped = {
            let _delivering = self.agent_message_delivery_lock();
            let pumped = match self.queued_message(session_id, id, recipient) {
                Ok(Some(_)) => self.record_handover(id, recipient, handover),
                // An unsend settled it with acpmux while the hand-over was
                // out: acpmux's answer stands.
                Ok(None) => {
                    self.remember_unnoted(id, recipient, false);
                    Pumped::Done
                }
                Err(_) => {
                    self.report_internal_diagnostic("agent message pump could not read a delivery");
                    let went_out = !matches!(handover, Handover::Unreachable);
                    self.remember_unnoted(id, recipient, went_out);
                    Pumped::Waits
                }
            };
            self.in_flight().remove(recipient);
            pumped
        };
        if pumped == Pumped::Done {
            self.wake_agent_message_pump();
        }
    }

    /// Records how `id`'s hand-over to `recipient`, still queued, went.
    fn record_handover(&self, id: &str, recipient: &str, handover: Handover) -> Pumped {
        let (state, error) = match handover {
            Handover::Delivered => ("delivered", None),
            Handover::Failed(error) => ("failed", Some(clip(&error, ERROR_MAX))),
            Handover::Unreachable => return Pumped::Unreachable,
            Handover::Unsettled(error) => {
                let noted = self.note_agent_message_attempt(id, recipient, &error).is_ok();
                if !noted {
                    self.report_internal_diagnostic("agent message pump could not note an attempt");
                }
                self.remember_unnoted(id, recipient, !noted);
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
        self.remember_unnoted(id, recipient, marked.is_err());
        if marked.is_err() {
            // The hand-over went out but is not recorded: the recipient
            // waits (nothing later overtakes it) and the backoff re-arms.
            self.report_internal_diagnostic("agent message pump could not record a delivery");
            return Pumped::Waits;
        }
        Pumped::Done
    }

    /// Fails a hand-over that went out but was not recorded closed: until a
    /// later record, an unsend treats `id`'s delivery to `recipient` as
    /// tried and asks acpmux about it.
    fn remember_unnoted(&self, id: &str, recipient: &str, unnoted: bool) {
        let key = (id.to_owned(), recipient.to_owned());
        let mut set = self.agent_message_pump.unnoted.lock().unwrap_or_else(|e| e.into_inner());
        if unnoted {
            set.insert(key);
        } else {
            set.remove(&key);
        }
    }

    /// Counts a hand-over acpmux never accepted on a delivery that stays
    /// queued, with why.
    fn note_agent_message_attempt(
        &self,
        id: &str,
        recipient: &str,
        error: &str,
    ) -> anyhow::Result<()> {
        let error = clip(error, ERROR_MAX);
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
