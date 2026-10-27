//! Resource-protocol streams as drains on the daemon-wide sequenced pool
//! (p01-process-204): the terminal, browser and sidebar attaches,
//! `session.events`, `session.journal.subscribe` and `conversation.events`.
//!
//! Each of these streams used to hold a `mux-resource-*` thread blocked on
//! its source and on the connection's room, so 24 views and a few
//! subscriptions held as many daemon threads. Like the attach streams
//! (attach_pump.rs, p05-ipc-079), each now is an [`AttachPump`]: a sequence
//! on the pool whose turn takes what its source holds while the stream has
//! room in the connection's [`super::BoundedOutbound`], and returns. The
//! source's ready hook, the writer's space hook and every close (the
//! connection, the stream or its cancel, the attachment) post the next turn.
//! Chrome binds each Mojo receiver to a sequence and never gives one a
//! thread (mojo/public/cpp/bindings/lib/connector.cc,
//! `Connector::OnWatcherHandleReady`; docs/threading_and_tasks.md "Prefer
//! sequences to threads").
//!
//! The drain checks the stream's backpressure room before each item, so it
//! sends with the non-waiting `send_stream` where the thread used
//! `send_stream_backpressured`: the same cap, without a wait. A source that
//! sends two items for one update (a browser state and frame) may pass the
//! cap by one, as the attach streams' browser view does.

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{Value, json};

use super::MessageWriter;
use super::OutboundStream;
use super::attach_lifecycle::attach_pump::{
    AttachDrain, AttachPump, PumpTimer, Step, TURN_BUDGET, Turn,
};
use super::sequenced_pool::SequencePriority;
use crate::Mux;
use crate::resource::StreamPublicId;
use crate::surface::AttachLifecycle;

/// A source's ready hook: the pump's wake, shareable among several sources
/// of one stream (the journal stream follows two epochs).
pub(super) type ReadyWake = Arc<dyn Fn() + Send + Sync>;

/// One `stream_item` of a resource stream: with a cursor (a resumable
/// stream), or without one (a view's snapshot and patches).
pub(super) struct StreamItem {
    pub(super) cursor: Option<Value>,
    pub(super) item: Value,
}

impl StreamItem {
    pub(super) fn uncursored(item: Value) -> Self {
        Self { cursor: None, item }
    }

    pub(super) fn at(cursor: Value, item: Value) -> Self {
        Self { cursor: Some(cursor), item }
    }
}

/// Where a resource stream's items go and what ends it.
pub(super) struct ResourceOut {
    pub(super) mux: Arc<Mux>,
    pub(super) client: u64,
    pub(super) writer: MessageWriter,
    pub(super) outbound: OutboundStream,
    pub(super) stream_id: StreamPublicId,
    canceled: Arc<AtomicBool>,
    lifecycle: Option<AttachLifecycle>,
    /// The `sequence` of the next item.
    sequence: u64,
}

impl ResourceOut {
    /// The stream has not ended: not canceled, its connection and outbound
    /// open, and its attachment (if it has one) not canceled.
    pub(super) fn is_live(&self) -> bool {
        !self.canceled.load(Ordering::Acquire)
            && self.writer.is_open()
            && self.outbound.is_open()
            && self.lifecycle.as_ref().is_none_or(|lifecycle| !lifecycle.is_canceled())
    }

    fn has_room(&self) -> bool {
        self.writer.sink.stream_has_room(&self.outbound)
    }

    /// Queues `item` as the stream's next `stream_item`. False ends the
    /// stream: its connection or outbound closed, or it overflowed (the
    /// connection then queued its `gap` end).
    pub(super) fn send(&mut self, item: StreamItem) -> bool {
        let sequence = self.sequence.to_string();
        let envelope = match item.cursor {
            Some(cursor) => json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_item",
                "stream_id":self.stream_id,
                "sequence":sequence,
                "cursor":cursor,
                "item":self.writer.project_conversation_tab_item(item.item),
            }),
            None => json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_item",
                "stream_id":self.stream_id,
                "sequence":sequence,
                "item":item.item,
            }),
        };
        let sent = self.writer.send_stream(&envelope, &self.outbound).is_ok();
        if sent {
            self.sequence = self.sequence.saturating_add(1);
        }
        sent
    }

    /// Queues `end` as the stream's terminal, dropping what it still queues.
    /// A canceled stream has its `canceled` end already; the connection
    /// keeps only the first terminal.
    pub(super) fn send_end(&self, end: &Value) {
        let _ = self.writer.send_terminal(end, &self.outbound);
    }

    /// Releases the stream's registration on its connection.
    pub(super) fn finish(&self) {
        self.mux.control_clients.finish_resource_stream(
            self.client,
            &self.stream_id,
            self.outbound.id,
        );
    }
}

/// A resource stream's source: what it sends after its initial items.
pub(super) trait ResourceSource: Send + Sized + 'static {
    /// Sends the source's next item on `out`, which has room for it.
    fn next(&mut self, out: &mut ResourceOut, timer: &PumpTimer<'_>) -> Step;

    /// The stream ended (its source ended, a send failed, or it closed):
    /// queues its end and releases it. False while its ordered end waits
    /// for room; the connection posts the next turn when it has some.
    fn finish(&mut self, out: &ResourceOut, timer: &PumpTimer<'_>) -> bool;
}

/// What a resource stream starts from.
pub(super) struct ResourceStart {
    pub(super) mux: Arc<Mux>,
    pub(super) client: u64,
    pub(super) writer: MessageWriter,
    pub(super) outbound: OutboundStream,
    pub(super) stream_id: StreamPublicId,
    pub(super) canceled: Arc<AtomicBool>,
    /// The attachment of a view stream: its cancel ends the stream.
    pub(super) lifecycle: Option<AttachLifecycle>,
    /// The `sequence` of the first item.
    pub(super) first_sequence: u64,
    /// Sent, in order, before the source's items.
    pub(super) initial: Vec<StreamItem>,
}

impl ResourceStart {
    /// The stream's drain on a pump at `priority`, not started: `on_ready`
    /// gives the source the pump's wake for its ready hooks. The caller
    /// starts the pump (after committing a view's attach).
    pub(super) fn bind<S: ResourceSource>(
        self,
        priority: SequencePriority,
        mut source: S,
        on_ready: impl FnOnce(&mut S, ReadyWake),
    ) -> AttachPump {
        let pump = AttachPump::new(&self.mux.sequenced_pool, priority);
        self.writer.register_interrupt(pump.stop());
        self.outbound.register_interrupt(pump.stop());
        if let Some(lifecycle) = self.lifecycle.as_ref() {
            lifecycle.register_interrupt(pump.stop());
        }
        self.outbound.on_space(pump.hook());
        on_ready(&mut source, Arc::new(pump.hook()));
        let out = ResourceOut {
            mux: self.mux,
            client: self.client,
            writer: self.writer,
            outbound: self.outbound,
            stream_id: self.stream_id,
            canceled: self.canceled,
            lifecycle: self.lifecycle,
            sequence: self.first_sequence,
        };
        pump.install(Box::new(ResourceDrain {
            out,
            initial: self.initial.into(),
            source,
            ended: false,
        }));
        pump
    }
}

/// A resource stream's drain: its initial items, then its source's.
struct ResourceDrain<S> {
    out: ResourceOut,
    initial: VecDeque<StreamItem>,
    source: S,
    /// The stream ended; only its end is left.
    ended: bool,
}

impl<S: ResourceSource> ResourceDrain<S> {
    fn drain(&mut self, timer: &PumpTimer<'_>) -> Turn {
        for _ in 0..TURN_BUDGET {
            if !self.out.is_live() {
                return Turn::Done;
            }
            if !self.out.has_room() {
                return Turn::Idle;
            }
            if let Some(item) = self.initial.pop_front() {
                if !self.out.send(item) {
                    return Turn::Done;
                }
                continue;
            }
            match self.source.next(&mut self.out, timer) {
                Step::Sent => {}
                Step::Bulk => return Turn::Yield,
                Step::Empty => return Turn::Idle,
                Step::End => return Turn::Done,
            }
        }
        Turn::Yield
    }
}

impl<S: ResourceSource> AttachDrain for ResourceDrain<S> {
    fn turn(&mut self, timer: &PumpTimer<'_>) -> Turn {
        if !self.ended {
            match self.drain(timer) {
                Turn::Done => self.ended = true,
                other => return other,
            }
        }
        if self.source.finish(&self.out, timer) { Turn::Done } else { Turn::Idle }
    }
}

#[cfg(test)]
#[path = "resource_pump_tests.rs"]
mod tests;
