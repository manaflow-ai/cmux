//! The connection message writer: `MessageSink`, the `MessageWriter` handle
//! every handler sends responses and events through, and `OutboundStream`,
//! a writer bound to one backpressured stream.

use super::AttachWireShape;
use super::BudgetedText;
use super::RenderService;
use super::VtStateMessage;
use super::conversation_tabs_wire;
use crate::AttachFrame;
use crate::SurfaceId;
use crate::mux::ResourceWaitWake;
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
        *self.overflow_text.lock().unwrap() = text;
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
        }
    }

    pub(super) fn start_stream(&self, overflow: &Value) -> std::io::Result<OutboundStream> {
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
        let result = self
            .render_service
            .serialize_control(value)
            .and_then(|text| self.sink.send_control(self.project_conversation_tabs(text)?));
        if result.is_err() {
            self.close();
        }
        result
    }

    pub(super) fn send_serialized_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result =
            self.project_conversation_tabs(text).and_then(|text| self.sink.send_control(text));
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
        let mut wakeups = self.wait_wakeups.lock().unwrap();
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
            let wakeups = std::mem::take(&mut *self.wait_wakeups.lock().unwrap());
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
            let wakeups = std::mem::take(&mut *self.wait_wakeups.lock().unwrap());
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
