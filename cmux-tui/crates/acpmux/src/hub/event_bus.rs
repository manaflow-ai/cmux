//! The hub's event broadcast, counted. Every record the hub publishes goes to every
//! connection's fan-out (`server/fanout.rs`) in one order; a request's reply goes from
//! its own task. Each send is numbered under one lock, and a fan-out learns the number
//! its receiver starts after, so it knows how many events it has handed on. A request's
//! reply waits until its connection's fan-out has handed on every event published before
//! the reply (`server::Conn::events_handed_on`): a turn's `session/update`s reach the
//! client before the `session/prompt` result that ends it, as ACP orders them, and no
//! reply ever overtakes an event its request caused.

use super::HubEvent;
use crate::no_panic::LockExt;
use std::sync::Mutex as StdMutex;
use tokio::sync::broadcast;

pub(crate) struct EventBus {
    tx: broadcast::Sender<HubEvent>,
    /// Events sent so far. Held across the send, so a count read under it names exactly
    /// the events a receiver made under it will not see.
    sent: StdMutex<u64>,
}

impl EventBus {
    pub(super) fn new(capacity: usize) -> Self {
        Self { tx: broadcast::channel(capacity).0, sent: StdMutex::new(0) }
    }

    /// Publishes `event` to every receiver, as `broadcast::Sender::send`.
    pub(crate) fn send(
        &self,
        event: HubEvent,
    ) -> Result<usize, broadcast::error::SendError<HubEvent>> {
        let mut sent = self.sent.lock_or_recover();
        *sent += 1;
        self.tx.send(event)
    }

    pub(crate) fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.tx.subscribe()
    }

    /// A receiver, and the number of events sent before it: it receives (or is told it
    /// lagged past) every later one.
    pub(crate) fn subscribe_counted(&self) -> (broadcast::Receiver<HubEvent>, u64) {
        let sent = self.sent.lock_or_recover();
        (self.tx.subscribe(), *sent)
    }

    /// The number of events sent so far.
    pub(crate) fn sent(&self) -> u64 {
        *self.sent.lock_or_recover()
    }
}

#[cfg(test)]
impl super::Hub {
    /// Publishes agent update `seq` of session `id` (`agent_message_chunk` with `text`),
    /// as the inbound loop's append does, with no session behind it.
    pub(crate) fn publish_test_update(&self, id: &str, seq: u64, text: &str) {
        let update = serde_json::json!({"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": text}});
        let record = crate::store::EventRecord {
            seq,
            at: crate::store::now_ms(),
            dir: "in".into(),
            kind: "agent_message_chunk".into(),
            msg: serde_json::json!({"jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": id, "update": update}}),
            host_seq: None,
        };
        let _ = self.events.send(HubEvent {
            session_id: id.to_owned(),
            record: std::sync::Arc::new(record),
            remote: None,
            update_line: Default::default(),
            summary: Default::default(),
        });
    }
}
