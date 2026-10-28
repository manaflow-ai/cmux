//! The queued message sink of a connection: a [`MessageSink`] over its
//! [`BoundedOutbound`], with the Unix or WebSocket stream its writer thread
//! writes to (moved out of bounded_outbound.rs).

use super::super::BudgetedText;
use super::super::MessageSink;
use super::super::OutboundStream;
use super::super::RENDER_ATTACH_MAX_BYTES;
use super::super::RoomWaker;
use super::super::attach_streams::AttachStreamAdmission;
use super::super::attach_streams::AttachStreamError;
use super::super::attach_streams::ClientStreamId;
use super::BoundedOutbound;
use crate::panic_free::RecoverPoison;
use crate::platform::transport;
use cmux_ipc::FrameHeader;
use cmux_threads::sync::Mutex;
use std::collections::VecDeque;
use std::io::Read;
use std::io::Write;
use std::net::Shutdown;
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

pub(in crate::server) struct QueuedSink {
    pub(in crate::server) outbound: Arc<BoundedOutbound>,
    pub(in crate::server) control: Option<SinkControl>,
}

pub(in crate::server) enum SinkControl {
    Unix(Box<dyn transport::Stream>),
    WebSocket(TcpStream),
}

/// Cloned TCP streams share one write boundary so independent Tungstenite
/// reader and writer contexts cannot interleave frame bytes. Reads remain
/// fully blocking and are interrupted by shutting down a clone.
pub(in crate::server) struct SynchronizedTcpStream {
    pub(in crate::server) stream: TcpStream,
    pub(in crate::server) write_lock: Arc<Mutex<()>>,
    /// Bytes already read from `stream` (the request head the listener read
    /// to tell a page request from a WebSocket handshake), read first.
    replay: VecDeque<u8>,
    /// Bytes this handle has read from `stream`: inbound liveness even while
    /// a large frame is still arriving.
    bytes_read: u64,
}

impl SynchronizedTcpStream {
    #[cfg(test)]
    pub(in crate::server) fn new(stream: TcpStream) -> Self {
        Self::with_replay(stream, Vec::new())
    }

    /// A stream whose reads return `replay` before reading `stream` again.
    pub(in crate::server) fn with_replay(stream: TcpStream, replay: Vec<u8>) -> Self {
        Self { stream, write_lock: Arc::new(Mutex::new(())), replay: replay.into(), bytes_read: 0 }
    }

    pub(in crate::server) fn try_clone(&self) -> std::io::Result<Self> {
        Ok(Self {
            stream: self.stream.try_clone()?,
            write_lock: self.write_lock.clone(),
            replay: VecDeque::new(),
            bytes_read: 0,
        })
    }

    /// Bytes read from the socket through this handle (replayed bytes excluded).
    pub(in crate::server) fn bytes_read(&self) -> u64 {
        self.bytes_read
    }

    pub(in crate::server) fn try_clone_raw(&self) -> std::io::Result<TcpStream> {
        self.stream.try_clone()
    }

    pub(in crate::server) fn set_read_timeout(
        &self,
        timeout: Option<Duration>,
    ) -> std::io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    pub(in crate::server) fn set_write_timeout(
        &self,
        timeout: Option<Duration>,
    ) -> std::io::Result<()> {
        self.stream.set_write_timeout(timeout)
    }

    /// One text message; its write calls count in `ipc` (`server-stats`).
    pub(in crate::server) fn write_websocket_text(
        &mut self,
        text: &str,
        ipc: &crate::diagnostics::IpcStats,
    ) -> std::io::Result<()> {
        if text.len() > RENDER_ATTACH_MAX_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "WebSocket outbound message exceeds the protocol limit",
            ));
        }
        let _guard = self.write_lock.lock().recover_poison();
        write_websocket_frame_to(&mut ipc.counted(&mut self.stream), 0x1, text.as_bytes())
    }

    pub(in crate::server) fn write_websocket_close(&mut self) -> std::io::Result<()> {
        self.write_websocket_frame(0x8, &[])
    }

    /// An empty Ping, written whole under the shared write lock so it never
    /// lands inside another frame.
    pub(in crate::server) fn write_websocket_ping(&mut self) -> std::io::Result<()> {
        self.write_websocket_frame(0x9, &[])
    }

    pub(in crate::server) fn write_websocket_frame(
        &mut self,
        opcode: u8,
        payload: &[u8],
    ) -> std::io::Result<()> {
        let _guard = self.write_lock.lock().recover_poison();
        write_websocket_frame_to(&mut self.stream, opcode, payload)
    }
}

/// One whole server frame; the caller holds the stream's write lock.
fn write_websocket_frame_to<W: Write + ?Sized>(
    out: &mut W,
    opcode: u8,
    payload: &[u8],
) -> std::io::Result<()> {
    let (header, header_len) = websocket_server_frame_header(opcode, payload.len());
    let header = header.get(..header_len).ok_or(std::io::ErrorKind::InvalidData)?;
    out.write_all(header)?;
    out.write_all(payload)?;
    out.flush()
}

pub(in crate::server) fn websocket_server_frame_header(
    opcode: u8,
    payload_len: usize,
) -> ([u8; 10], usize) {
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
        if !self.replay.is_empty() {
            return self.replay.read(buf);
        }
        let read = self.stream.read(buf)?;
        self.bytes_read += read as u64;
        Ok(read)
    }
}

impl Write for SynchronizedTcpStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _guard = self.write_lock.lock().recover_poison();
        self.stream.write_all(buf)?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let _guard = self.write_lock.lock().recover_poison();
        self.stream.flush()
    }
}

impl SinkControl {
    pub(in crate::server) fn set_write_timeout(
        &self,
        timeout: Option<Duration>,
    ) -> std::io::Result<()> {
        match self {
            Self::Unix(stream) => stream.set_write_timeout(timeout),
            Self::WebSocket(stream) => stream.set_write_timeout(timeout),
        }
    }

    pub(in crate::server) fn shutdown(&self) -> std::io::Result<()> {
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

    fn stream_has_room(&self, stream: &OutboundStream) -> bool {
        self.outbound.has_backpressure_room(stream)
    }

    fn claim_client_stream(
        &self,
        stream: &OutboundStream,
        admission: &Arc<AttachStreamAdmission>,
    ) -> Result<(), AttachStreamError> {
        self.outbound.claim_client_stream(stream, admission)
    }

    fn client_stream(&self, id: ClientStreamId) -> Option<OutboundStream> {
        self.outbound.client_stream(id)
    }

    fn set_stream_lane(&self, stream: &OutboundStream, lane: cmux_ipc::StreamLane) {
        self.outbound.set_stream_lane(stream, lane);
    }

    fn send_frame(&self, header: FrameHeader, text: Arc<BudgetedText>) -> std::io::Result<()> {
        match self.control {
            Some(SinkControl::Unix(_)) => self.outbound.push_frame(header, text),
            // Frames are granted only to local Unix peers.
            Some(SinkControl::WebSocket(_)) | None => Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "frames ride only a local Unix connection",
            )),
        }
    }

    fn send_stream_frame(
        &self,
        header: FrameHeader,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        match self.control {
            Some(SinkControl::Unix(_)) => self.outbound.push_stream_frame(header, text, stream),
            Some(SinkControl::WebSocket(_)) | None => Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "frames ride only a local Unix connection",
            )),
        }
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

    fn try_send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
        on_room: RoomWaker,
    ) -> std::io::Result<bool> {
        self.outbound.try_push_ordered_terminal(text, stream, on_room)
    }

    fn send_stream_end(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_stream_end(text, stream)
    }

    fn is_open(&self) -> bool {
        self.outbound.is_open()
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        // A socket the mux-io loop writes does not block: its timeout is
        // the queue's (server/mux_io.rs). A writer thread's socket keeps
        // `SO_SNDTIMEO`.
        self.outbound.set_write_timeout(timeout);
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
