//! The connection message writer: `MessageSink`, the `MessageWriter` handle
//! every handler sends responses and events through, and `OutboundStream`,
//! a writer bound to one backpressured stream.

use super::AttachWireShape;
use super::BudgetedText;
use super::RenderService;
use super::VtStateMessage;
use super::api_revision_wire;
use super::attach_frames;
use super::attach_frames::BudgetedFrame;
use super::attach_frames::FrameKind;
use super::attach_frames::StreamFraming;
use super::conversation_tabs_wire;
use crate::AttachFrame;
use crate::SurfaceId;
use crate::mux::ResourceWaitWake;
use crate::panic_free::JsonFields;
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

/// One message on a connection: a JSON line, or a binary attach frame
/// (`attach-frames-v1`, server/attach_frames.rs).
#[derive(Clone)]
pub(super) enum WireMessage {
    Line(Arc<BudgetedText>),
    Frame(Arc<BudgetedFrame>),
}

impl WireMessage {
    pub(super) fn len(&self) -> usize {
        match self {
            Self::Line(text) => text.len(),
            Self::Frame(frame) => frame.len(),
        }
    }
}

impl From<Arc<BudgetedText>> for WireMessage {
    fn from(text: Arc<BudgetedText>) -> Self {
        Self::Line(text)
    }
}

impl From<Arc<BudgetedFrame>> for WireMessage {
    fn from(frame: Arc<BudgetedFrame>) -> Self {
        Self::Frame(frame)
    }
}

#[derive(Clone)]
pub(super) struct OutboundStream {
    pub(super) id: u64,
    pub(super) open: Arc<AtomicBool>,
    pub(super) terminal_enqueued: Arc<AtomicBool>,
    /// The stream's terminal item on overflow: the legacy `overflow` event,
    /// or a client stream's `stream-end` with reason `overflow`.
    pub(super) overflow_text: Arc<Mutex<WireMessage>>,
    /// How the stream's items are written (client id, frames).
    pub(super) framing: StreamFraming,
    /// Fired by `close`, so stream loops block instead of polling `is_open`.
    pub(super) closed: InterruptSet,
}

impl OutboundStream {
    pub(super) fn new(id: u64, overflow_text: Arc<BudgetedText>) -> Self {
        Self::with_framing(id, overflow_text.into(), StreamFraming::LEGACY)
    }

    pub(super) fn with_framing(
        id: u64,
        overflow_text: WireMessage,
        framing: StreamFraming,
    ) -> Self {
        Self {
            id,
            open: Arc::new(AtomicBool::new(true)),
            terminal_enqueued: Arc::new(AtomicBool::new(false)),
            overflow_text: Arc::new(Mutex::new(overflow_text)),
            framing,
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

    pub(super) fn update_overflow(&self, text: WireMessage) {
        *self.overflow_text.lock().recover_poison() = text;
    }
}

pub(super) trait MessageSink: Send + Sync {
    fn send_initial(&self, text: WireMessage, stream: &OutboundStream) -> std::io::Result<()>;
    fn send_stream(&self, text: WireMessage, stream: &OutboundStream) -> std::io::Result<()>;
    fn send_stream_backpressured(
        &self,
        text: WireMessage,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.send_stream(text, stream)
    }
    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()>;
    fn send_terminal(&self, text: WireMessage, stream: &OutboundStream) -> std::io::Result<()>;
    fn send_ordered_terminal(
        &self,
        text: WireMessage,
        stream: &OutboundStream,
    ) -> std::io::Result<()>;
    /// A client stream's `stream-end`: after every item already admitted
    /// for the stream, also when the stream is already closed, never
    /// waiting, at most once per stream (`terminal_enqueued`).
    fn send_stream_end(&self, text: WireMessage, stream: &OutboundStream) -> std::io::Result<()>;
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
        }
    }

    pub(super) fn start_stream(&self, overflow: &Value) -> std::io::Result<OutboundStream> {
        self.start_framed_stream(overflow, StreamFraming::LEGACY)
    }

    /// A stream written with `framing`. A client stream's overflow item is its
    /// `stream-end` with reason `overflow` (it carries `overflow`'s fields).
    pub(super) fn start_framed_stream(
        &self,
        overflow: &Value,
        framing: StreamFraming,
    ) -> std::io::Result<OutboundStream> {
        let id = self.next_stream_id.fetch_add(1, Ordering::Relaxed);
        let overflow = self.overflow_message(overflow, framing)?;
        Ok(OutboundStream::with_framing(id, overflow, framing))
    }

    fn overflow_message(
        &self,
        overflow: &Value,
        framing: StreamFraming,
    ) -> std::io::Result<WireMessage> {
        if framing.id.is_none() {
            return Ok(self.render_service.serialize_control(overflow)?.into());
        }
        let mut end = overflow.clone();
        if let Some(fields) = end.as_object_mut() {
            fields.insert("event".into(), Value::from("stream-end"));
            fields.insert("reason".into(), Value::from("overflow"));
        }
        let text = self.render_service.serialize_control(&end)?;
        self.frame_event(text, framing, &self.render_service.control_budget)
    }

    pub(super) fn update_stream_overflow(
        &self,
        stream: &OutboundStream,
        overflow: &Value,
    ) -> std::io::Result<()> {
        stream.update_overflow(self.overflow_message(overflow, stream.framing)?);
        Ok(())
    }

    /// One serialized JSON event as `framing` writes it: an EVENT frame, the
    /// object tagged with its `stream`, or the line unchanged (legacy).
    fn frame_event(
        &self,
        text: Arc<BudgetedText>,
        framing: StreamFraming,
        budget: &Arc<super::render_service::OutboundByteBudget>,
    ) -> std::io::Result<WireMessage> {
        if let Some(stream) = framing.frame_stream() {
            return Ok(attach_frames::encode_frame(
                budget,
                FrameKind::Event,
                stream,
                0,
                &[text.as_bytes()],
            )?
            .into());
        }
        let Some(stream) = framing.id else { return Ok(text.into()) };
        let tagged = attach_frames::tag_json_object(&text, stream).ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "stream event is not a JSON object",
            )
        })?;
        drop(text);
        let mut writer = super::render_service::BudgetedJsonWriter::new(budget.clone());
        std::io::Write::write_all(&mut writer, tagged.as_bytes())?;
        Ok(writer.finish().into())
    }

    fn stream_event<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<WireMessage> {
        let text = self.render_service.serialize(value)?;
        self.frame_event(text, stream.framing, &self.render_service.outbound_budget)
    }

    fn stream_control_event<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<WireMessage> {
        let text = self.render_service.serialize_control(value)?;
        self.frame_event(text, stream.framing, &self.render_service.control_budget)
    }

    /// Closes the stream on any failure but a full queue (the caller reports
    /// that as overflow).
    fn stream_result(stream: &OutboundStream, result: std::io::Result<()>) -> std::io::Result<()> {
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    fn ensure_open(&self) -> std::io::Result<()> {
        if self.is_open() {
            Ok(())
        } else {
            Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"))
        }
    }

    pub(super) fn send_stream<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        let result = self
            .stream_event(value, stream)
            .and_then(|message| self.sink.send_stream(message, stream));
        Self::stream_result(stream, result)
    }

    /// Send an ordered state stream without mistaking a healthy slow client
    /// for a disconnected one. Its source must retain or coalesce updates
    /// while this call waits for the socket writer to accept the prior item.
    pub(super) fn send_stream_backpressured<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        let result = self
            .stream_event(value, stream)
            .and_then(|message| self.sink.send_stream_backpressured(message, stream));
        Self::stream_result(stream, result)
    }

    pub(super) fn send_initial<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        let result = self
            .stream_event(value, stream)
            .and_then(|message| self.sink.send_initial(message, stream));
        Self::stream_result(stream, result)
    }

    /// PTY output `bytes` starting at stream offset `offset` as OUTPUT frames
    /// of at most [`attach_frames::OUTPUT_FRAME_MAX`] bytes, on a frames stream
    /// (the caller decided; a JSON stream gets its own `output` event shape).
    /// Waits like [`Self::send_stream_backpressured`].
    pub(super) fn send_output_frames(
        &self,
        bytes: &[u8],
        offset: u64,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        let Some(id) = stream.framing.frame_stream() else {
            return Err(std::io::Error::other("OUTPUT frames need a frames stream"));
        };
        let mut at = offset;
        for chunk in bytes.chunks(attach_frames::OUTPUT_FRAME_MAX) {
            let result = attach_frames::encode_frame(
                &self.render_service.outbound_budget,
                FrameKind::Output,
                id,
                at,
                &[chunk],
            )
            .and_then(|frame| self.sink.send_stream_backpressured(frame.into(), stream));
            Self::stream_result(stream, result)?;
            at += chunk.len() as u64;
        }
        Ok(())
    }

    /// A frame whose payload is JSON `meta` then raw `data` (SNAPSHOT,
    /// SNAPSHOT_MORE, REPLAY, GRID) on a frames stream, else `legacy()` as a
    /// line. `initial` sends it ahead of the stream's queue (the attach's
    /// first READY, before the reply), else it waits like
    /// [`Self::send_stream_backpressured`].
    #[allow(clippy::too_many_arguments)]
    pub(super) fn send_meta_frame(
        &self,
        kind: FrameKind,
        meta: &Value,
        data: &[&[u8]],
        offset: u64,
        legacy: impl FnOnce() -> Value,
        stream: &OutboundStream,
        initial: bool,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        let Some(id) = stream.framing.frame_stream() else {
            let legacy = legacy();
            return if initial {
                self.send_initial(&legacy, stream)
            } else {
                self.send_stream_backpressured(&legacy, stream)
            };
        };
        let result = attach_frames::encode_meta_frame(
            &self.render_service.outbound_budget,
            kind,
            id,
            offset,
            meta,
            data,
        )
        .and_then(|frame| {
            if initial {
                self.sink.send_initial(frame.into(), stream)
            } else {
                self.sink.send_stream_backpressured(frame.into(), stream)
            }
        });
        Self::stream_result(stream, result)
    }

    pub(super) fn send_initial_vt_state(
        &self,
        value: &VtStateMessage,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        if stream.framing.frame_stream().is_some() {
            let meta = self.replay_meta(
                &*self.render_service.serialize_vt_state(&VtStateMessage {
                    replay: Arc::from([]),
                    pending_sequence: Arc::from([]),
                    kitty_image_aliases: value.kitty_image_aliases.clone(),
                    colors: value.colors.clone(),
                    ..*value
                })?,
                value.pending_sequence.len(),
            )?;
            return self.send_meta_frame(
                FrameKind::Replay,
                &meta,
                &[&value.replay, &value.pending_sequence],
                0,
                || Value::Null,
                stream,
                true,
            );
        }
        let result = self
            .render_service
            .serialize_vt_state(value)
            .and_then(|text| {
                self.frame_event(text, stream.framing, &self.render_service.outbound_budget)
            })
            .and_then(|message| self.sink.send_initial(message, stream));
        Self::stream_result(stream, result)
    }

    /// The JSON meta of a REPLAY frame: the replay event serialized without
    /// its bytes, plus how many trailing payload bytes are the pending
    /// sequence. It re-reads the serializer's text (one parse per replay): a
    /// REPLAY goes only to a byte-replay frames stream at attach and resize, and
    /// one serializer keeps the meta's fields identical to the JSON event's.
    fn replay_meta(&self, empty: &BudgetedText, pending_len: usize) -> std::io::Result<Value> {
        let mut meta: Value = serde_json::from_str(empty).map_err(std::io::Error::other)?;
        if let Some(fields) = meta.as_object_mut() {
            fields.remove("data");
            fields.remove("replay");
            fields.remove("pending");
            fields.insert("pending_len".into(), Value::from(pending_len));
        }
        Ok(meta)
    }

    pub(super) fn send_attach_frame_backpressured(
        &self,
        surface: SurfaceId,
        frame: &AttachFrame,
        shape: AttachWireShape,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        if stream.framing.frame_stream().is_some() {
            return self.send_attach_frame_as_frames(surface, frame, shape, stream);
        }
        let result = self
            .render_service
            .serialize_attach_frame(surface, frame, shape)
            .and_then(|text| {
                self.frame_event(text, stream.framing, &self.render_service.outbound_budget)
            })
            .and_then(|message| self.sink.send_stream_backpressured(message, stream));
        Self::stream_result(stream, result)
    }

    /// A byte-replay attach's frame as binary frames. Its OUTPUT offsets are
    /// 0: a replay stream has no snapshot offsets to continue.
    fn send_attach_frame_as_frames(
        &self,
        surface: SurfaceId,
        frame: &AttachFrame,
        shape: AttachWireShape,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        match frame {
            AttachFrame::Output(output) => self.send_output_frames(output, 0, stream),
            AttachFrame::OutputWithColors { output, colors } => {
                self.send_output_frames(output, 0, stream)?;
                self.send_attach_frame_backpressured(
                    surface,
                    &AttachFrame::ColorsChanged(Arc::new(**colors)),
                    shape,
                    stream,
                )
            }
            AttachFrame::Resized { replay, pending_sequence, .. }
            | AttachFrame::ResizedWithColors { replay, pending_sequence, .. } => {
                let Some(empty) = without_replay_bytes(frame) else {
                    return Err(std::io::Error::other("a resize frame without its resize"));
                };
                let empty = self.render_service.serialize_attach_frame(
                    surface,
                    &empty,
                    AttachWireShape { pending_sequence: true, ..shape },
                )?;
                let meta = self.replay_meta(&empty, pending_sequence.len())?;
                self.send_meta_frame(
                    FrameKind::Replay,
                    &meta,
                    &[replay, pending_sequence],
                    0,
                    || Value::Null,
                    stream,
                    false,
                )
            }
            AttachFrame::ColorsChanged(_) => {
                let result = self
                    .render_service
                    .serialize_attach_frame(surface, frame, shape)
                    .and_then(|text| {
                        self.frame_event(text, stream.framing, &self.render_service.outbound_budget)
                    })
                    .and_then(|message| self.sink.send_stream_backpressured(message, stream));
                Self::stream_result(stream, result)
            }
        }
    }

    pub(super) fn send_terminal<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        let result = self
            .stream_control_event(value, stream)
            .and_then(|message| self.sink.send_terminal(message, stream));
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
        self.ensure_open()?;
        let result = self
            .stream_control_event(value, stream)
            .and_then(|message| self.sink.send_ordered_terminal(message, stream));
        if result.is_err() {
            self.close();
        }
        result
    }

    /// The RING frame of a ring stream: the ring's read-only descriptor
    /// (passed with the frame), its capacity and base, at its current end.
    /// Sent ahead of the stream's queue, before its READY.
    #[cfg(unix)]
    pub(super) fn send_ring(
        &self,
        ring: &crate::surface::SharedOutputRing,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        let Some(id) = stream.framing.frame_stream() else {
            return Err(std::io::Error::other("a ring needs a frames stream"));
        };
        let (meta, end, descriptor) = {
            let ring = ring.lock().recover_poison();
            let meta = serde_json::json!({
                "layout": crate::surface::output_ring::LAYOUT,
                "capacity": ring.capacity(),
                "base": ring.base(),
            });
            (meta, ring.end(), ring.reader_descriptor().try_clone()?)
        };
        let meta = serde_json::to_vec(&meta).map_err(std::io::Error::other)?;
        let result = attach_frames::encode_frame_passing(
            &self.render_service.outbound_budget,
            FrameKind::Ring,
            id,
            end,
            &[&meta],
            descriptor,
        )
        .and_then(|frame| self.sink.send_initial(frame.into(), stream));
        Self::stream_result(stream, result)
    }

    /// A ring stream's RING_ADVANCE: the ring holds the stream's bytes up to
    /// `end`. Waits like [`Self::send_stream_backpressured`].
    #[cfg(unix)]
    pub(super) fn send_ring_advance(
        &self,
        end: u64,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.ensure_open()?;
        let Some(id) = stream.framing.frame_stream() else {
            return Err(std::io::Error::other("a ring needs a frames stream"));
        };
        let result = attach_frames::encode_frame(
            &self.render_service.outbound_budget,
            FrameKind::RingAdvance,
            id,
            end,
            &[],
        )
        .and_then(|frame| self.sink.send_stream_backpressured(frame.into(), stream));
        Self::stream_result(stream, result)
    }

    /// Ends `stream` with its overflow item (set when it started), purging
    /// its queued items.
    pub(super) fn send_stream_overflow(&self, stream: &OutboundStream) -> std::io::Result<()> {
        self.ensure_open()?;
        let message = stream.overflow_text.lock().recover_poison().clone();
        let result = self.sink.send_terminal(message, stream);
        if result.is_err() {
            self.close();
        }
        result
    }

    /// Ends a client stream (`attach-streams-v1`) with its `stream-end`
    /// after every item already queued for it, so the client may reuse the id.
    /// A legacy stream has no end item. At most once per stream.
    pub(super) fn end_client_stream(&self, stream: &OutboundStream, surface: Option<SurfaceId>) {
        if stream.framing.id.is_none() || !self.is_open() {
            return;
        }
        let mut end = serde_json::json!({"event": "stream-end", "reason": "ended"});
        if let Some(surface) = surface {
            end.insert("surface", serde_json::json!(surface));
        }
        let message = self.render_service.serialize_control(&end).and_then(|text| {
            self.frame_event(text, stream.framing, &self.render_service.control_budget)
        });
        match message.and_then(|message| self.sink.send_stream_end(message, stream)) {
            Ok(()) => {}
            // The client cannot tell this stream ended: the connection is no
            // longer coherent, so it ends (the client reattaches everything).
            Err(_) => self.close(),
        }
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

    pub(super) fn send_serialized_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .project_conversation_tabs(text)
            .and_then(|text| self.project_api_revision(text))
            .and_then(|text| self.sink.send_control(text));
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

/// A resize replay frame with its replay and pending bytes left out: the
/// serializer's JSON of it is a REPLAY frame's meta. `None` for any other frame.
fn without_replay_bytes(frame: &AttachFrame) -> Option<AttachFrame> {
    match frame {
        AttachFrame::Resized { cols, rows, kitty_image_aliases, kitty_state, .. } => {
            Some(AttachFrame::Resized {
                cols: *cols,
                rows: *rows,
                replay: Arc::from([]),
                kitty_image_aliases: kitty_image_aliases.clone(),
                kitty_state: *kitty_state,
                pending_sequence: Arc::from([]),
            })
        }
        AttachFrame::ResizedWithColors {
            cols,
            rows,
            kitty_image_aliases,
            kitty_state,
            colors,
            ..
        } => Some(AttachFrame::ResizedWithColors {
            cols: *cols,
            rows: *rows,
            replay: Arc::from([]),
            kitty_image_aliases: kitty_image_aliases.clone(),
            kitty_state: *kitty_state,
            colors: colors.clone(),
            pending_sequence: Arc::from([]),
        }),
        _ => None,
    }
}
