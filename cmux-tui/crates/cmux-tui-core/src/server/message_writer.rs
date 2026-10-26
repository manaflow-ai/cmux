//! The connection message writer: `MessageSink`, the `MessageWriter` handle
//! every handler sends responses and events through, and `OutboundStream`,
//! a writer bound to one backpressured stream.
//!
//! Order (spec/transports.md "Reply and event order"): replies and the items
//! of control-sequence streams (`start_control_stream`) share the
//! connection's control FIFO, so a reply is written after every control event
//! enqueued before it; every other stream keeps its own FIFO. A framed
//! request's reply is a frame in that same FIFO (`send_reply`). Every other
//! stream rides a lane (`StreamLane`): input streams before the control FIFO,
//! bulk and background streams after it (server/outbound_lanes.rs).

use super::AttachWireShape;
use super::BudgetedText;
use super::RenderService;
use super::VtStateMessage;
use super::api_revision_wire;
use super::conversation_tabs_wire;
use super::frame_dispatch::FrameCall;
use crate::AttachFrame;
use crate::SurfaceId;
use crate::mux::ResourceWaitWake;
use crate::panic_free::RecoverPoison;
use crate::stream_interrupt::InterruptSet;
use crate::stream_interrupt::StreamInterrupt;
use cmux_ipc::{FrameHeader, StreamLane};
use cmux_threads::sync::Mutex;
use serde::Serialize;
use serde_json::Value;
use std::sync::Arc;
use std::sync::Weak;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;

#[derive(Clone)]
pub(super) struct OutboundStream {
    pub(super) id: u64,
    pub(super) open: Arc<AtomicBool>,
    /// The stream rides the connection's control sequence (stream 0): its
    /// items share the reply FIFO. False for every other stream.
    pub(super) control_sequence: bool,
    /// The outbound lane of a stream outside the control sequence.
    pub(super) lane: StreamLane,
    pub(super) terminal_enqueued: Arc<AtomicBool>,
    pub(super) overflow_text: Arc<Mutex<Arc<BudgetedText>>>,
    /// Fired by `close`, so stream loops block instead of polling `is_open`.
    pub(super) closed: InterruptSet,
}

impl OutboundStream {
    #[cfg(test)]
    pub(super) fn new(id: u64, overflow_text: Arc<BudgetedText>) -> Self {
        Self::with_sequence(id, overflow_text, false, StreamLane::Bulk)
    }

    fn with_sequence(
        id: u64,
        overflow_text: Arc<BudgetedText>,
        control_sequence: bool,
        lane: StreamLane,
    ) -> Self {
        Self {
            id,
            open: Arc::new(AtomicBool::new(true)),
            control_sequence,
            lane,
            terminal_enqueued: Arc::new(AtomicBool::new(false)),
            overflow_text: Arc::new(Mutex::new(overflow_text)),
            closed: InterruptSet::default(),
        }
    }

    pub(super) fn register_interrupt(&self, interrupt: &Arc<StreamInterrupt>) {
        self.closed.register(interrupt);
    }

    pub(super) fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire)
    }

    pub(super) fn close(&self) {
        self.open.store(false, Ordering::Release);
        self.closed.fire();
    }

    pub(super) fn update_overflow(&self, text: Arc<BudgetedText>) {
        *self.overflow_text.lock().recover_poison() = text;
    }
}

pub(super) trait MessageSink: Send + Sync {
    fn send_initial(&self, text: Arc<BudgetedText>, stream: &OutboundStream)
    -> std::io::Result<()>;
    fn send_stream(&self, text: Arc<BudgetedText>, stream: &OutboundStream) -> std::io::Result<()>;
    fn send_stream_backpressured(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.send_stream(text, stream)
    }
    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()>;
    /// `text` as the payload of a frame with `header`, in the control FIFO
    /// with replies and control events. Only a local Unix connection that
    /// granted frames carries them.
    fn send_frame(&self, _header: FrameHeader, _text: Arc<BudgetedText>) -> std::io::Result<()> {
        Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "this sink carries no frames"))
    }
    /// `text` as the payload of a frame with `header` on `stream`'s FIFO,
    /// cut at the connection's BULK_FRAME_MAX. Only a local Unix connection
    /// that granted frames carries them.
    fn send_stream_frame(
        &self,
        _header: FrameHeader,
        _text: Arc<BudgetedText>,
        _stream: &OutboundStream,
    ) -> std::io::Result<()> {
        Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "this sink carries no frames"))
    }
    fn send_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()>;
    fn send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()>;
    fn set_write_timeout(&self, _timeout: Option<Duration>) -> std::io::Result<()> {
        Ok(())
    }
    fn flush_control(&self, _timeout: Duration) -> std::io::Result<()> {
        Ok(())
    }
    fn is_open(&self) -> bool;
    fn close(&self);
    fn abort(&self) {
        self.close();
    }
    fn close_after_control(&self) {
        self.close();
    }
}

/// Transport-independent writer shared by command responses and event streams.
#[derive(Clone)]
pub(super) struct MessageWriter {
    pub(super) sink: Arc<dyn MessageSink>,
    pub(super) open: Arc<AtomicBool>,
    pub(super) next_stream_id: Arc<AtomicU64>,
    pub(super) render_service: Arc<RenderService>,
    pub(super) wait_wakeups: Arc<Mutex<Vec<Weak<ResourceWaitWake>>>>,
    /// Fired when the writer closes, so stream loops block instead of polling `is_open`.
    pub(super) closed: InterruptSet,
    /// Negotiated conversation tab capabilities (server/conversation_tabs_wire.rs).
    pub(super) conversation_tabs: Arc<conversation_tabs_wire::NegotiatedTabs>,
    /// Negotiated API revision (server/api_revision_wire.rs).
    pub(super) api_revision: Arc<api_revision_wire::NegotiatedRevision>,
    /// The framed request this writer answers (`replying_to`): its reply
    /// leaves as that request's REPLY or ERROR frame. `None` on the
    /// connection's own writer and for every line.
    pub(super) reply: Option<Arc<FrameCall>>,
    /// The connection's caller class for `debug-daemon-locks`, read by its
    /// reader and dispatcher with no lock (server/origin_gate.rs sets it).
    pub(super) lock_caller: Arc<crate::diagnostics::LockCallerCell>,
}

impl MessageWriter {
    #[cfg(test)]
    pub(super) fn new(sink: impl MessageSink + 'static) -> Self {
        Self::new_with_render_service(sink, Arc::new(RenderService::new()))
    }

    pub(super) fn new_with_render_service(
        sink: impl MessageSink + 'static,
        render_service: Arc<RenderService>,
    ) -> Self {
        Self {
            sink: Arc::new(sink),
            open: Arc::new(AtomicBool::new(true)),
            next_stream_id: Arc::new(AtomicU64::new(1)),
            render_service,
            wait_wakeups: Arc::new(Mutex::new(Vec::new())),
            closed: InterruptSet::default(),
            conversation_tabs: Arc::default(),
            api_revision: Arc::default(),
            reply: None,
            lock_caller: Arc::default(),
        }
    }

    /// This connection's writer, answering the framed request `call`: like
    /// the responder Mojo hands a method with a response
    /// (chromium mojo/public/cpp/bindings/lib/interface_endpoint_client.cc,
    /// `ResponderThunk`), it knows where the reply goes. Everything else it
    /// sends goes where the connection's writer sends it.
    pub(super) fn replying_to(&self, call: Arc<FrameCall>) -> Self {
        Self { reply: Some(call), ..self.clone() }
    }

    /// The connection's writer, answering no framed request.
    pub(super) fn connection_writer(&self) -> Self {
        Self { reply: None, ..self.clone() }
    }

    /// The framed request this writer answers.
    pub(super) fn frame_call(&self) -> Option<&Arc<FrameCall>> {
        self.reply.as_ref()
    }

    /// The reply to the request this writer answers: a JSON line, or, for a
    /// framed request, the same JSON as its REPLY frame (ERROR when `ok` is
    /// false). Only the first reply of a framed request is framed.
    pub(super) fn send_reply(&self, reply: &Value) -> std::io::Result<()> {
        if self.reply.as_ref().is_none_or(|call| call.is_answered()) {
            return self.send_control(reply);
        }
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let ok = reply.get("ok") != Some(&Value::Bool(false));
        let result = self.render_service.serialize_control(reply).and_then(|text| {
            self.send_framed_reply(
                self.project_api_revision(self.project_conversation_tabs(text)?)?,
                ok,
            )
        });
        if result.is_err() {
            self.close();
        }
        result
    }

    /// `text`, projected already, as the framed request's reply, if this
    /// writer answers one that has none yet; else as a control line.
    fn send_framed_reply(&self, text: Arc<BudgetedText>, ok: bool) -> std::io::Result<()> {
        match self.reply.as_ref().filter(|call| call.claim_reply()) {
            Some(call) => {
                let header = call.reply_header(ok, text.len()).map_err(|bad| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, bad.to_string())
                })?;
                self.sink.send_frame(header, text)
            }
            None => self.sink.send_control(text),
        }
    }

    /// A bulk stream: snapshots, replays and output nobody is typing into.
    pub(super) fn start_stream(&self, overflow: &Value) -> std::io::Result<OutboundStream> {
        self.start_stream_on(StreamLane::Bulk, overflow)
    }

    /// A stream with its own FIFO on `lane`.
    pub(super) fn start_stream_on(
        &self,
        lane: StreamLane,
        overflow: &Value,
    ) -> std::io::Result<OutboundStream> {
        Ok(OutboundStream::with_sequence(
            self.next_stream_id.fetch_add(1, Ordering::Relaxed),
            self.render_service.serialize_control(overflow)?,
            false,
            lane,
        ))
    }

    /// A stream on the connection's control sequence: its items are written
    /// in one FIFO with command replies (the `subscribe` events and the
    /// `session.events` state items the app's event barrier counts). It keeps
    /// its own stream budget and backpressure; it never spends the control
    /// reserve.
    pub(super) fn start_control_stream(&self, overflow: &Value) -> std::io::Result<OutboundStream> {
        Ok(OutboundStream::with_sequence(
            self.next_stream_id.fetch_add(1, Ordering::Relaxed),
            self.render_service.serialize_control(overflow)?,
            true,
            StreamLane::Bulk,
        ))
    }

    pub(super) fn update_stream_overflow(
        &self,
        stream: &OutboundStream,
        overflow: &Value,
    ) -> std::io::Result<()> {
        stream.update_overflow(self.render_service.serialize_control(overflow)?);
        Ok(())
    }

    pub(super) fn send_stream<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize(value)
            .and_then(|text| self.sink.send_stream(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    /// A frame on `stream` whose payload is `text`: one longer than the
    /// connection's BULK_FRAME_MAX leaves in chunks, so replies and
    /// input-lane items pass it between chunks.
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "p05-ipc-076 OUTPUT/SNAPSHOT frames are its first producer")
    )]
    pub(super) fn send_stream_frame(
        &self,
        header: FrameHeader,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_stream_frame(header, text, stream);
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    /// Send an ordered state stream without mistaking a healthy slow client
    /// for a disconnected one. Its source must retain or coalesce updates
    /// while this call waits for the socket writer to accept the prior item.
    pub(super) fn send_stream_backpressured<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        self.send_encoded_backpressured(self.encode(value), stream)
    }

    /// The first half of [`Self::send_stream_backpressured`]: `value` as
    /// the text it sends. An echo thread watches this half as its frame's
    /// work, not the hand-off that waits for room.
    pub(super) fn encode<T: Serialize + ?Sized>(
        &self,
        value: &T,
    ) -> std::io::Result<Arc<BudgetedText>> {
        self.render_service.serialize(value)
    }

    /// [`Self::encode`] of an attach frame in `shape`.
    pub(super) fn encode_attach_frame(
        &self,
        surface: SurfaceId,
        frame: &AttachFrame,
        shape: AttachWireShape,
    ) -> std::io::Result<Arc<BudgetedText>> {
        self.render_service.serialize_attach_frame(surface, frame, shape)
    }

    /// The second half of [`Self::send_stream_backpressured`]: hand the
    /// encoded text to the stream, waiting while its queue is full. A failed
    /// encode or hand-off closes the stream, as the whole send does.
    pub(super) fn send_encoded_backpressured(
        &self,
        encoded: std::io::Result<Arc<BudgetedText>>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = encoded.and_then(|text| self.sink.send_stream_backpressured(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    pub(super) fn send_initial<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize(value)
            .and_then(|text| self.sink.send_initial(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    pub(super) fn send_initial_vt_state(
        &self,
        value: &VtStateMessage,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_vt_state(value)
            .and_then(|text| self.sink.send_initial(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    pub(super) fn send_terminal<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_control(value)
            .and_then(|text| self.sink.send_terminal(text, stream));
        if result.is_err() {
            self.close();
        }
        result
    }

    pub(super) fn send_ordered_terminal<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_control(value)
            .and_then(|text| self.sink.send_ordered_terminal(text, stream));
        if result.is_err() {
            self.close();
        }
        result
    }

    pub(super) fn send_control<T: Serialize + ?Sized>(&self, value: &T) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.render_service.serialize_control(value).and_then(|text| {
            self.sink
                .send_control(self.project_api_revision(self.project_conversation_tabs(text)?)?)
        });
        if result.is_err() {
            self.close();
        }
        result
    }

    /// A successful reply serialized ahead (`vt-state` writes its budgeted
    /// reply itself); like `send_reply`, the REPLY frame of a framed request.
    pub(super) fn send_serialized_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .project_conversation_tabs(text)
            .and_then(|text| self.project_api_revision(text))
            .and_then(|text| self.send_framed_reply(text, true));
        if result.is_err() {
            self.close();
        }
        result
    }

    pub(super) fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire) && self.sink.is_open()
    }

    pub(super) fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.sink.set_write_timeout(timeout)
    }

    pub(super) fn flush_control(&self, timeout: Duration) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.flush_control(timeout);
        if result.is_err() {
            self.abort();
        }
        result
    }

    /// Fires `interrupt` when this writer closes (at once if it is closed).
    pub(super) fn register_interrupt(&self, interrupt: &Arc<StreamInterrupt>) {
        self.closed.register(interrupt);
        if !self.is_open() {
            interrupt.fire();
        }
    }

    pub(super) fn register_wait_wakeup(&self, wake: &Arc<ResourceWaitWake>) {
        let mut wakeups = self.wait_wakeups.lock().recover_poison();
        wakeups.retain(|registered| registered.strong_count() > 0);
        if self.is_open() {
            wakeups.push(Arc::downgrade(wake));
        } else {
            drop(wakeups);
            wake.notify();
        }
    }

    pub(super) fn close_with(&self, preserve_control: bool) {
        if self.open.swap(false, Ordering::AcqRel) {
            let wakeups = std::mem::take(&mut *self.wait_wakeups.lock().recover_poison());
            for wake in wakeups.into_iter().filter_map(|wake| wake.upgrade()) {
                wake.notify();
            }
            self.closed.fire();
            if preserve_control {
                self.sink.close_after_control();
            } else {
                self.sink.close();
            }
        }
    }

    pub(super) fn abort(&self) {
        if self.open.swap(false, Ordering::AcqRel) {
            let wakeups = std::mem::take(&mut *self.wait_wakeups.lock().recover_poison());
            for wake in wakeups.into_iter().filter_map(|wake| wake.upgrade()) {
                wake.notify();
            }
            self.closed.fire();
        }
        self.sink.abort();
    }

    pub(super) fn close_after_control(&self) {
        self.close_with(true);
    }

    pub(super) fn close(&self) {
        self.close_with(false);
    }
}
