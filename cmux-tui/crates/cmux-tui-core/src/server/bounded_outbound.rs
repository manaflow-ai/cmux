//! Per-connection bounded outbound queues: the regular, control and stream
//! queues with their item and byte budgets, connection permits, the writer
//! thread loop that frames JSON lines or WebSocket text frames, and the
//! queued message sink over a synchronized TCP stream.

use super::BACKPRESSURE_RECHECK;
use super::BudgetedText;
use super::MAX_SERVER_CONNECTIONS;
use super::MessageSink;
use super::OUTBOUND_BACKPRESSURED_STREAM_CAPACITY;
use super::OUTBOUND_BYTE_CAPACITY;
use super::OUTBOUND_CAPACITY;
use super::OUTBOUND_CONNECTION_BYTE_CAPACITY;
use super::OUTBOUND_CONNECTION_CAPACITY;
use super::OUTBOUND_CONTROL_BYTE_RESERVE;
use super::OUTBOUND_CONTROL_RESERVE;
use super::OutboundStream;
use super::RENDER_ATTACH_MAX_BYTES;
use crate::platform::transport;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::io::Read;
use std::io::Write;
use std::net::Shutdown;
use std::net::TcpStream;
use std::sync::Arc;
use std::sync::Condvar;
use std::sync::Mutex;
use std::sync::atomic::Ordering;
use std::time::Duration;

#[derive(Default)]
pub(super) struct BoundedOutbound {
    pub(super) state: Mutex<BoundedOutboundState>,
    pub(super) changed: Condvar,
}

#[derive(Default)]
pub(super) struct BoundedOutboundState {
    pub(super) initial: VecDeque<RegularOutbound>,
    pub(super) control: VecDeque<ControlOutbound>,
    pub(super) regular: VecDeque<RegularOutbound>,
    pub(super) stream_usage: HashMap<u64, StreamOutboundUsage>,
    pub(super) control_messages: usize,
    pub(super) control_bytes: usize,
    pub(super) regular_bytes: usize,
    pub(super) closed: bool,
}

pub(super) struct StreamOutboundUsage {
    messages: usize,
    bytes: usize,
    stream: OutboundStream,
}

pub(super) struct RegularOutbound {
    text: Arc<BudgetedText>,
    stream: OutboundStream,
}

pub(super) enum ControlOutbound {
    Text(Arc<BudgetedText>),
    Flush(std::sync::mpsc::SyncSender<()>),
}

pub(super) enum OutboundItem {
    Text(Arc<BudgetedText>),
    Flush(std::sync::mpsc::SyncSender<()>),
}

#[derive(Clone)]
pub(super) struct ConnectionPermit {
    pub(super) _lease: Arc<ConnectionPermitLease>,
}

pub(super) struct ConnectionPermitLease(Arc<crate::diagnostics::ConnectionStats>);

impl Drop for ConnectionPermitLease {
    fn drop(&mut self) {
        self.0.release();
    }
}

pub(super) fn claim_connection(
    connections: &Arc<crate::diagnostics::ConnectionStats>,
) -> Option<ConnectionPermit> {
    connections
        .try_claim(MAX_SERVER_CONNECTIONS as u64)
        .then(|| ConnectionPermit { _lease: Arc::new(ConnectionPermitLease(connections.clone())) })
}

impl BoundedOutbound {
    pub(super) fn push_regular(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.push_regular_with_priority(text, stream, false)
    }

    pub(super) fn push_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.push_regular_with_priority(text, stream, true)
    }

    pub(super) fn push_regular_with_priority(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
        initial: bool,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        let result = Self::push_regular_locked(&mut state, text, stream, initial);
        drop(state);
        self.changed.notify_all();
        result
    }

    pub(super) fn push_regular_backpressured(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        loop {
            if state.closed {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "connection closed",
                ));
            }
            if !stream.is_open() {
                return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
            }
            let pending =
                state.stream_usage.get(&stream.id).map(|usage| usage.messages).unwrap_or_default();
            if pending < OUTBOUND_BACKPRESSURED_STREAM_CAPACITY {
                let result = Self::push_regular_locked(&mut state, text, stream, false);
                drop(state);
                self.changed.notify_all();
                return result;
            }
            let (next, _) = self.changed.wait_timeout(state, BACKPRESSURE_RECHECK).unwrap();
            state = next;
        }
    }

    pub(super) fn push_regular_locked(
        state: &mut BoundedOutboundState,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
        initial: bool,
    ) -> std::io::Result<()> {
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        if !stream.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
        }
        let bytes = text.len();
        if bytes > OUTBOUND_BYTE_CAPACITY {
            Self::terminate_stream_locked(state, stream)?;
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound queue overflowed",
            ));
        }
        let (stream_messages, stream_bytes) = state
            .stream_usage
            .get(&stream.id)
            .map(|usage| (usage.messages, usage.bytes))
            .unwrap_or_default();
        if stream_messages >= OUTBOUND_CAPACITY
            || bytes > OUTBOUND_BYTE_CAPACITY.saturating_sub(stream_bytes)
        {
            Self::terminate_stream_locked(state, stream)?;
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound stream queue overflowed",
            ));
        }
        loop {
            let byte_full =
                bytes > OUTBOUND_CONNECTION_BYTE_CAPACITY.saturating_sub(state.regular_bytes);
            let count_full =
                state.initial.len() + state.regular.len() >= OUTBOUND_CONNECTION_CAPACITY;
            if !byte_full && !count_full {
                break;
            }
            let Some(victim) = Self::largest_stream(state, byte_full) else {
                Self::terminate_stream_locked(state, stream)?;
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            };
            let incoming_terminated = victim.id == stream.id;
            Self::terminate_stream_locked(state, &victim)?;
            if incoming_terminated {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            }
        }
        state.regular_bytes += bytes;
        let usage = state.stream_usage.entry(stream.id).or_insert_with(|| StreamOutboundUsage {
            messages: 0,
            bytes: 0,
            stream: stream.clone(),
        });
        usage.messages += 1;
        usage.bytes += bytes;
        let message = RegularOutbound { text, stream: stream.clone() };
        if initial {
            state.initial.push_back(message);
        } else {
            state.regular.push_back(message);
        }
        Ok(())
    }

    pub(super) fn push_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        Self::push_control_locked(&mut state, text)?;
        self.changed.notify_one();
        Ok(())
    }

    pub(super) fn flush_control(&self, timeout: Duration) -> std::io::Result<()> {
        let (flushed_tx, flushed_rx) = std::sync::mpsc::sync_channel(1);
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        state.control.push_back(ControlOutbound::Flush(flushed_tx));
        drop(state);
        self.changed.notify_one();
        match flushed_rx.recv_timeout(timeout) {
            Ok(()) => Ok(()),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "timed out while flushing the shutdown response",
            )),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "connection closed while flushing the shutdown response",
            )),
        }
    }

    pub(super) fn push_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        stream.close();
        Self::purge_stream_locked(&mut state, stream.id);
        if stream.terminal_enqueued.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        Self::push_control_locked(&mut state, text)?;
        self.changed.notify_one();
        Ok(())
    }

    /// Gracefully closes a stream after every item already admitted for it.
    ///
    /// Overflow and cancellation use `push_terminal`, which intentionally
    /// purges stale items. Successful bounded replay must preserve FIFO order.
    pub(super) fn push_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let bytes = text.len();
        if bytes > OUTBOUND_BYTE_CAPACITY {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound stream terminal exceeds its byte capacity",
            ));
        }
        let mut state = self.state.lock().unwrap();
        loop {
            if state.closed {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "connection closed",
                ));
            }
            if stream.terminal_enqueued.load(Ordering::Acquire) {
                return Ok(());
            }
            if !stream.is_open() {
                return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
            }
            let (stream_messages, stream_bytes) = state
                .stream_usage
                .get(&stream.id)
                .map(|usage| (usage.messages, usage.bytes))
                .unwrap_or_default();
            let stream_full = stream_messages >= OUTBOUND_CAPACITY
                || bytes > OUTBOUND_BYTE_CAPACITY.saturating_sub(stream_bytes);
            let connection_full = state.initial.len() + state.regular.len()
                >= OUTBOUND_CONNECTION_CAPACITY
                || bytes > OUTBOUND_CONNECTION_BYTE_CAPACITY.saturating_sub(state.regular_bytes);
            if !stream_full && !connection_full {
                state.regular_bytes += bytes;
                let usage = state.stream_usage.entry(stream.id).or_insert_with(|| {
                    StreamOutboundUsage { messages: 0, bytes: 0, stream: stream.clone() }
                });
                usage.messages += 1;
                usage.bytes += bytes;
                state.regular.push_back(RegularOutbound { text, stream: stream.clone() });
                stream.terminal_enqueued.store(true, Ordering::Release);
                stream.close();
                drop(state);
                self.changed.notify_all();
                return Ok(());
            }
            let (next, _) = self.changed.wait_timeout(state, BACKPRESSURE_RECHECK).unwrap();
            state = next;
        }
    }

    pub(super) fn terminate_stream_locked(
        state: &mut BoundedOutboundState,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        stream.close();
        Self::purge_stream_locked(state, stream.id);
        if stream.terminal_enqueued.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let overflow_text = stream.overflow_text.lock().unwrap().clone();
        if let Err(error) = Self::push_control_locked(state, overflow_text) {
            state.closed = true;
            return Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                format!("could not report stream overflow: {error}"),
            ));
        }
        Ok(())
    }

    pub(super) fn purge_stream_locked(state: &mut BoundedOutboundState, stream_id: u64) {
        state.initial.retain(|message| message.stream.id != stream_id);
        state.regular.retain(|message| message.stream.id != stream_id);
        if let Some(usage) = state.stream_usage.remove(&stream_id) {
            state.regular_bytes = state.regular_bytes.saturating_sub(usage.bytes);
        }
    }

    pub(super) fn largest_stream(
        state: &BoundedOutboundState,
        by_bytes: bool,
    ) -> Option<OutboundStream> {
        state
            .stream_usage
            .values()
            .filter(|usage| !usage.stream.terminal_enqueued.load(Ordering::Acquire))
            .max_by_key(|usage| if by_bytes { usage.bytes } else { usage.messages })
            .map(|usage| usage.stream.clone())
    }

    pub(super) fn push_control_locked(
        state: &mut BoundedOutboundState,
        text: Arc<BudgetedText>,
    ) -> std::io::Result<()> {
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let bytes = text.len();
        if state.control_messages >= OUTBOUND_CONTROL_RESERVE
            || bytes > OUTBOUND_CONTROL_BYTE_RESERVE.saturating_sub(state.control_bytes)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound control reserve overflowed",
            ));
        }
        state.control_messages += 1;
        state.control_bytes += bytes;
        state.control.push_back(ControlOutbound::Text(text));
        Ok(())
    }

    #[cfg(test)]
    pub(super) fn try_pop(&self) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        loop {
            match Self::pop_locked(&mut state) {
                Some(OutboundItem::Text(text)) => {
                    drop(state);
                    self.changed.notify_all();
                    return Some(text.to_string());
                }
                Some(OutboundItem::Flush(flushed)) => {
                    drop(state);
                    self.changed.notify_all();
                    let _ = flushed.send(());
                    state = self.state.lock().unwrap();
                }
                None => return None,
            }
        }
    }

    pub(super) fn recv(&self) -> Option<OutboundItem> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(item) = Self::pop_locked(&mut state) {
                drop(state);
                self.changed.notify_all();
                return Some(item);
            }
            if state.closed {
                return None;
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    pub(super) fn pop_locked(state: &mut BoundedOutboundState) -> Option<OutboundItem> {
        if let Some(message) = state.initial.pop_front() {
            Self::record_stream_pop(state, &message);
            return Some(OutboundItem::Text(message.text));
        }
        if let Some(control) = state.control.pop_front() {
            return Some(match control {
                ControlOutbound::Text(text) => {
                    state.control_messages = state.control_messages.saturating_sub(1);
                    state.control_bytes = state.control_bytes.saturating_sub(text.len());
                    OutboundItem::Text(text)
                }
                ControlOutbound::Flush(flushed) => OutboundItem::Flush(flushed),
            });
        }
        let message = state.regular.pop_front()?;
        Self::record_stream_pop(state, &message);
        Some(OutboundItem::Text(message.text))
    }

    pub(super) fn record_stream_pop(state: &mut BoundedOutboundState, message: &RegularOutbound) {
        let bytes = message.text.len();
        state.regular_bytes = state.regular_bytes.saturating_sub(bytes);
        let remove = state.stream_usage.get_mut(&message.stream.id).is_some_and(|usage| {
            usage.messages = usage.messages.saturating_sub(1);
            usage.bytes = usage.bytes.saturating_sub(bytes);
            usage.messages == 0
        });
        if remove {
            state.stream_usage.remove(&message.stream.id);
        }
    }

    pub(super) fn is_open(&self) -> bool {
        !self.state.lock().unwrap().closed
    }

    pub(super) fn close(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        state.control.retain(|item| matches!(item, ControlOutbound::Text(_)));
        drop(state);
        self.changed.notify_all();
    }

    pub(super) fn abort(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        for usage in state.stream_usage.values() {
            usage.stream.close();
        }
        state.initial.clear();
        state.control.clear();
        state.regular.clear();
        state.stream_usage.clear();
        state.control_messages = 0;
        state.control_bytes = 0;
        state.regular_bytes = 0;
        drop(state);
        self.changed.notify_all();
    }

    pub(super) fn close_after_control(&self) {
        let mut state = self.state.lock().unwrap();
        for usage in state.stream_usage.values() {
            usage.stream.close();
        }
        state.initial.clear();
        state.regular.clear();
        state.stream_usage.clear();
        state.regular_bytes = 0;
        state.closed = true;
        drop(state);
        self.changed.notify_all();
    }
}

pub(super) fn write_line_outbound_item<W: Write + ?Sized>(
    writer: &mut W,
    item: OutboundItem,
) -> std::io::Result<()> {
    match item {
        OutboundItem::Text(text) => {
            writer.write_all(text.as_bytes())?;
            writer.write_all(b"\n")
        }
        OutboundItem::Flush(flushed) => {
            writer.flush()?;
            let _ = flushed.send(());
            Ok(())
        }
    }
}

pub(super) struct QueuedSink {
    pub(super) outbound: Arc<BoundedOutbound>,
    pub(super) control: Option<SinkControl>,
}

pub(super) enum SinkControl {
    Unix(Box<dyn transport::Stream>),
    WebSocket(TcpStream),
}

/// Cloned TCP streams share one write boundary so independent Tungstenite
/// reader and writer contexts cannot interleave frame bytes. Reads remain
/// fully blocking and are interrupted by shutting down a clone.
pub(super) struct SynchronizedTcpStream {
    pub(super) stream: TcpStream,
    pub(super) write_lock: Arc<Mutex<()>>,
}

impl SynchronizedTcpStream {
    pub(super) fn new(stream: TcpStream) -> Self {
        Self { stream, write_lock: Arc::new(Mutex::new(())) }
    }

    pub(super) fn try_clone(&self) -> std::io::Result<Self> {
        Ok(Self { stream: self.stream.try_clone()?, write_lock: self.write_lock.clone() })
    }

    pub(super) fn try_clone_raw(&self) -> std::io::Result<TcpStream> {
        self.stream.try_clone()
    }

    pub(super) fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    pub(super) fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.stream.set_write_timeout(timeout)
    }

    pub(super) fn write_websocket_text(&mut self, text: &str) -> std::io::Result<()> {
        if text.len() > RENDER_ATTACH_MAX_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "WebSocket outbound message exceeds the protocol limit",
            ));
        }
        self.write_websocket_frame(0x1, text.as_bytes())
    }

    pub(super) fn write_websocket_close(&mut self) -> std::io::Result<()> {
        self.write_websocket_frame(0x8, &[])
    }

    pub(super) fn write_websocket_frame(
        &mut self,
        opcode: u8,
        payload: &[u8],
    ) -> std::io::Result<()> {
        let (header, header_len) = websocket_server_frame_header(opcode, payload.len());
        let _guard = self.write_lock.lock().unwrap();
        self.stream.write_all(&header[..header_len])?;
        self.stream.write_all(payload)?;
        self.stream.flush()
    }
}

pub(super) fn websocket_server_frame_header(opcode: u8, payload_len: usize) -> ([u8; 10], usize) {
    let mut header = [0_u8; 10];
    header[0] = 0x80 | (opcode & 0x0f);
    match payload_len {
        0..=125 => {
            header[1] = payload_len as u8;
            (header, 2)
        }
        126..=65_535 => {
            header[1] = 126;
            header[2..4].copy_from_slice(&(payload_len as u16).to_be_bytes());
            (header, 4)
        }
        _ => {
            header[1] = 127;
            header[2..10].copy_from_slice(&(payload_len as u64).to_be_bytes());
            (header, 10)
        }
    }
}

impl Read for SynchronizedTcpStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.stream.read(buf)
    }
}

impl Write for SynchronizedTcpStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _guard = self.write_lock.lock().unwrap();
        self.stream.write_all(buf)?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let _guard = self.write_lock.lock().unwrap();
        self.stream.flush()
    }
}

impl SinkControl {
    pub(super) fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        match self {
            Self::Unix(stream) => stream.set_write_timeout(timeout),
            Self::WebSocket(stream) => stream.set_write_timeout(timeout),
        }
    }

    pub(super) fn shutdown(&self) -> std::io::Result<()> {
        match self {
            Self::Unix(stream) => stream.shutdown(Shutdown::Both),
            Self::WebSocket(stream) => stream.shutdown(Shutdown::Both),
        }
    }
}

impl MessageSink for QueuedSink {
    fn send_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_initial(text, stream)
    }

    fn send_stream(&self, text: Arc<BudgetedText>, stream: &OutboundStream) -> std::io::Result<()> {
        self.outbound.push_regular(text, stream)
    }

    fn send_stream_backpressured(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_regular_backpressured(text, stream)
    }

    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        self.outbound.push_control(text)
    }

    fn send_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_terminal(text, stream)
    }

    fn send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_ordered_terminal(text, stream)
    }

    fn is_open(&self) -> bool {
        self.outbound.is_open()
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.control.as_ref().map_or(Ok(()), |control| control.set_write_timeout(timeout))
    }

    fn flush_control(&self, timeout: Duration) -> std::io::Result<()> {
        self.control.as_ref().map_or(Ok(()), |_| self.outbound.flush_control(timeout))
    }

    fn close(&self) {
        self.outbound.close();
    }

    fn abort(&self) {
        self.outbound.abort();
        if let Some(control) = &self.control {
            let _ = control.shutdown();
        }
    }

    fn close_after_control(&self) {
        self.outbound.close_after_control();
    }
}
