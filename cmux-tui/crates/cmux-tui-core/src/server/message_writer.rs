//! The connection message writer: `MessageSink`, the `MessageWriter` handle
//! every handler sends responses and events through, and `OutboundStream`,
//! a writer bound to one backpressured stream.

use super::AttachWireShape;
use super::BudgetedText;
use super::RenderService;
use super::VtStateMessage;
use super::api_revision_wire;
use super::conversation_tabs_wire;
use super::tree_reply_text::TreeReply;
use crate::AttachFrame;
use crate::SurfaceId;
use crate::mux::ResourceWaitWake;
use crate::panic_free::RecoverPoison;
use crate::stream_interrupt::InterruptSet;
use crate::stream_interrupt::StreamInterrupt;
use serde::Serialize;
use serde_json::Value;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::Weak;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;

pub(super) mod long_connection;

#[derive(Clone)]
pub(super) struct OutboundStream {
    pub(super) id: u64,
    pub(super) open: Arc<AtomicBool>,
    pub(super) terminal_enqueued: Arc<AtomicBool>,
    pub(super) overflow_text: Arc<Mutex<Arc<BudgetedText>>>,
    /// Fired by `close`, so stream loops block instead of polling `is_open`.
    pub(super) closed: InterruptSet,
}

impl OutboundStream {
    pub(super) fn new(id: u64, overflow_text: Arc<BudgetedText>) -> Self {
        Self {
            id,
            open: Arc::new(AtomicBool::new(true)),
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
    /// [`Self::send_control`] for a sender that may wait until `deadline`
    /// for room in a control queue that is full. A sink with no such queue
    /// sends at once.
    fn send_control_backpressured(
        &self,
        text: Arc<BudgetedText>,
        _deadline: Instant,
    ) -> std::io::Result<()> {
        self.send_control(text)
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
    /// How many lines this connection wrote so far, in socket order, when the sink counts them.
    fn lines_written(&self) -> Option<u64> {
        None
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
    /// Whether this connection carries the person's keys: its threads then run at user-interactive QoS
    /// (server/input_qos.rs).
    pub(super) input_lane: Arc<super::input_qos::InputLane>,
    /// What the daemon knows about the client at the other end, for the request counters
    /// (diagnostics/command_stats.rs): a request reads it here, never in the client registry.
    pub(super) kind: Arc<crate::diagnostics::ConnectionKind>,
    /// The connection's way out of the terminals' short lane when it starts a stream, a wait or
    /// a follow (server/message_writer/long_connection.rs).
    pub(super) long: Arc<long_connection::LongGate>,
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
            input_lane: Arc::default(),
            kind: Arc::default(),
            long: Arc::default(),
        }
    }

    /// A stream outlives its request, so a terminal's connection becomes a long one first
    /// (server/message_writer/long_connection.rs). At the bound of the long connections no stream starts: the
    /// error holds a `LongConnectionsFull`.
    pub(super) fn start_stream(&self, overflow: &Value) -> std::io::Result<OutboundStream> {
        self.long.hold().map_err(std::io::Error::other)?;
        Ok(OutboundStream::new(
            self.next_stream_id.fetch_add(1, Ordering::Relaxed),
            self.render_service.serialize_control(overflow)?,
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
        let result = self
            .render_service
            .serialize(value)
            .and_then(|text| self.sink.send_stream_backpressured(text, stream));
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

    pub(super) fn send_attach_frame_backpressured(
        &self,
        surface: SurfaceId,
        frame: &AttachFrame,
        shape: AttachWireShape,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_attach_frame(surface, frame, shape)
            .and_then(|text| self.sink.send_stream_backpressured(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    /// [`MessageWriter::send_stream_backpressured`] of a snapshot viewer's
    /// `output` event ([`RenderService::serialize_snapshot_output`]).
    pub(super) fn send_snapshot_output_backpressured(
        &self,
        surface: SurfaceId,
        output: &[u8],
        (generation, offset): (u64, u64),
        colors: Option<&Value>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_snapshot_output(surface, output, generation, offset, colors)
            .and_then(|text| self.sink.send_stream_backpressured(text, stream));
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
        self.send_control_with_room_by(value, None)
    }

    /// [`Self::send_control`] for a thread that may wait: a control queue
    /// with no room for the message has until `deadline` to get it, where
    /// `send_control` closes the connection at once. For more than one large
    /// message to one connection at one time, off its reader thread.
    pub(super) fn send_control_backpressured<T: Serialize + ?Sized>(
        &self,
        value: &T,
        deadline: Instant,
    ) -> std::io::Result<()> {
        self.send_control_with_room_by(value, Some(deadline))
    }

    fn send_control_with_room_by<T: Serialize + ?Sized>(
        &self,
        value: &T,
        deadline: Option<Instant>,
    ) -> std::io::Result<()> {
        self.send_rendered_control(deadline, false, |render| {
            let lap = crate::measure_probe::now();
            let text = render.serialize_control(value);
            crate::measure_probe::since("reply.text", lap);
            text
        })
    }

    /// [`Self::send_control`] of a message that this call owns (a v2 response). A connection
    /// that did not negotiate each tab capability gets its projection on the value, before the
    /// message's one text. The text path (`project_conversation_tabs`) parses the whole message
    /// and writes it a second time, which for a `session.snapshot` is the whole session.
    pub(super) fn send_control_value(&self, mut value: Value) -> std::io::Result<()> {
        let projection = self.tab_projection();
        if !projection.is_canonical() {
            let lap = crate::measure_probe::now();
            projection.project(&mut value);
            crate::measure_probe::since("tabs.value_walk", lap);
        }
        let sent = self.send_rendered_control(None, true, |render| {
            let lap = crate::measure_probe::now();
            let text = render.serialize_control(&value);
            crate::measure_probe::since("reply.text", lap);
            text
        });
        let lap = crate::measure_probe::now();
        drop(value);
        crate::measure_probe::since("ss.drop_reply_value", lap);
        sent
    }

    /// A `list-workspaces` reply written from its build's shared tree text:
    /// the bytes [`Self::send_control`] sends of its `Response`, through the
    /// same projections for this connection's capabilities.
    pub(super) fn send_tree_reply(
        &self,
        tree: &TreeReply,
        id: Option<&Value>,
    ) -> std::io::Result<()> {
        // The tree's text has this connection's tab projection (`TreeReply`). An `id` that is
        // an array or an object is the one part of the reply that the tree's text does not
        // hold and that the projection reads: such a reply takes the text path, which changes
        // nothing more in a tree that is projected.
        let tabs_projected = !id.is_some_and(|id| id.is_array() || id.is_object());
        self.send_rendered_control(None, tabs_projected, |render| {
            let lap = crate::measure_probe::now();
            let text = render.write_control(tree.text.reply_bytes(), |out| {
                tree.text.write_reply(out, id, tree.lines_written_before_read)
            });
            crate::measure_probe::since("lw.copy", lap);
            text
        })
    }

    /// Sends the control message that `render` makes, as [`Self::send_control`] does.
    /// `tabs_projected`: the message already is what this connection reads of the tab kinds, so
    /// its text is not parsed for them.
    fn send_rendered_control(
        &self,
        deadline: Option<Instant>,
        tabs_projected: bool,
        render: impl FnOnce(&RenderService) -> std::io::Result<Arc<BudgetedText>>,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = render(&self.render_service).and_then(|text| {
            let text = if tabs_projected { text } else { self.project_conversation_tabs(text)? };
            let lap = crate::measure_probe::now();
            let text = self.project_api_revision(text)?;
            crate::measure_probe::since("reply.api_revision", lap);
            let lap = crate::measure_probe::now();
            let text = self.mark_reply(text);
            let sent = match deadline {
                Some(deadline) => self.sink.send_control_backpressured(text, deadline),
                None => self.sink.send_control(text),
            };
            crate::measure_probe::since("reply.queue", lap);
            sent
        });
        if result.is_err() {
            self.close();
        }
        result
    }

    /// Marks `text` as the reply of the request this thread handles for this connection, if it
    /// handles one and no other connection shares the text (diagnostics/request_log.rs).
    fn mark_reply(&self, mut text: Arc<BudgetedText>) -> Arc<BudgetedText> {
        if let Some(unique) = Arc::get_mut(&mut text)
            && unique.reply.is_none()
        {
            unique.reply =
                crate::diagnostics::request_log::reply_mark(&self.open, unique.text.len());
        }
        text
    }

    pub(super) fn send_serialized_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .project_conversation_tabs(text)
            .and_then(|text| self.project_api_revision(text))
            .and_then(|text| self.sink.send_control(self.mark_reply(text)));
        if result.is_err() {
            self.close();
        }
        result
    }

    pub(super) fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire) && self.sink.is_open()
    }

    /// The lines this connection wrote so far, in socket order (``MessageSink::lines_written``).
    /// Read before a command reads state, it is the read barrier the reply names (#32408).
    pub(super) fn lines_written(&self) -> Option<u64> {
        self.sink.lines_written()
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
