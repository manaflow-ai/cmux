//! [`RescueBackend`]: `cmux.terminal.backend/1` for kind `cloud-vm-rescue`.
//!
//! The local session host owns the VT state, history and snapshots; this
//! backend only moves bytes between it and a [`RescueTransport`] stream.
//! It is the only writer of each rescue terminal's stream state. Bytes move
//! as frames with the shared credit rule (`cmux-terminal-iface`): input data
//! in offset order within the `in` credit (a gap, an overlap or data past
//! the credit ends the terminal with `lost`); output data within the `out`
//! credit, offsets the running byte total; one `end` (`exit` or `lost`)
//! after the last output, then nothing; after `close` every call is refused
//! and nothing queues.

use super::stream::{Status, Stream};
use super::transport::{RescueTransport, StreamId, TransportEvent};
use cmux_terminal_iface::{
    BackendCapabilities, BackendError, BackendId, ByteTerminal, Close, DEFAULT_WINDOW_BYTES,
    Direction, End, ExitStatus, FrameBody, Grid, LocalId, Lost, MAX_EXIT_MESSAGE, OpenRequest,
    ResumeRequest, ResumeToken, Resumed, Signal, TerminalBackend, allow_kind, check_kinds,
};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

pub const RESCUE_KIND: &str = "cloud-vm-rescue";
pub const RESCUE_ID: &str = "rescue";

/// One input data frame at most (a paste is split by the session host).
const MAX_WRITE_BYTES: usize = 64 * 1024;
/// Longest signal name kept from the far end (`exit.signal`).
const MAX_SIGNAL_NAME: usize = 32;

/// Cuts far-end text to at most `max` bytes, on a char boundary.
fn cut(text: &mut String, max: usize) {
    if text.len() > max {
        let mut end = max;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
}

fn bounded(mut status: ExitStatus) -> ExitStatus {
    if let Some(message) = &mut status.message {
        cut(message, MAX_EXIT_MESSAGE);
    }
    if let Some(signal) = &mut status.signal {
        cut(signal, MAX_SIGNAL_NAME);
    }
    status
}

struct Inner {
    transport: Box<dyn RescueTransport>,
    streams: HashMap<StreamId, Stream>,
}

impl Inner {
    /// Moves transport events to their terminals.
    fn pump(&mut self) {
        for (id, event) in self.transport.take_events() {
            let Some(stream) = self.streams.get_mut(&id) else { continue };
            if stream.status != Status::Open {
                continue;
            }
            match event {
                TransportEvent::Output(bytes) => stream.output(bytes),
                // The transport frees a stream that closed or dropped by
                // itself (RescueTransport contract): never close it again.
                TransportEvent::Closed(status) => {
                    stream.released = true;
                    stream.finish(End::Exit(bounded(status)));
                }
                TransportEvent::Dropped { mut reason, retryable } => {
                    cut(&mut reason, MAX_EXIT_MESSAGE);
                    stream.released = true;
                    stream.finish(End::Lost(Lost::new(reason, retryable)));
                }
            }
        }
    }

    fn open_stream(&mut self, id: StreamId) -> Result<&mut Stream, BackendError> {
        self.pump();
        match self.streams.get_mut(&id) {
            Some(stream) if stream.status == Status::Open => Ok(stream),
            _ => Err(BackendError::not_open()),
        }
    }

    /// Closes the transport stream once (it is gone for the terminal either way).
    fn release(&mut self, id: StreamId) {
        if let Some(stream) = self.streams.get_mut(&id)
            && !std::mem::replace(&mut stream.released, true)
        {
            // A refusal changes nothing: the stream is gone either way.
            let _refused = self.transport.close(id);
        }
    }

    /// A failed input write ends the stream: the terminal shows it lost
    /// (after the output it already has) and the transport stream is closed once.
    fn fail(&mut self, id: StreamId, error: BackendError) -> BackendError {
        if let Some(stream) = self.streams.get_mut(&id) {
            let mut reason = error.to_string();
            cut(&mut reason, MAX_EXIT_MESSAGE);
            stream.finish(End::Lost(Lost::new(reason, error.retryable())));
        }
        self.release(id);
        error
    }

    /// A frame that breaks the credit rule ends the terminal with `lost`.
    fn violate(&mut self, id: StreamId, lost: Lost) {
        if let Some(stream) = self.streams.get_mut(&id) {
            stream.violate(lost);
        }
        self.release(id);
    }

    /// One input data frame: written to the transport, then credited.
    fn write(&mut self, id: StreamId, offset: u64, bytes: Vec<u8>) -> Result<(), BackendError> {
        if bytes.len() > MAX_WRITE_BYTES {
            return Err(BackendError::invalid(format!(
                "one data frame carries at most {MAX_WRITE_BYTES} bytes"
            )));
        }
        let stream = self.open_stream(id)?;
        if let Err(lost) = stream.input.receive(offset, bytes.len()) {
            self.violate(id, lost);
            return Ok(());
        }
        if bytes.is_empty() {
            return Ok(());
        }
        if let Err(error) = self.transport.write(id, &bytes) {
            return Err(self.fail(id, error));
        }
        if let Some(stream) = self.streams.get_mut(&id)
            && let Ok(Some(credit)) = stream.input.consume(Direction::In, bytes.len() as u64)
        {
            stream.queue(credit);
        }
        Ok(())
    }

    /// One frame from the session host.
    fn push(&mut self, id: StreamId, frame: FrameBody) -> Result<(), BackendError> {
        let (offset, bytes) = match frame {
            FrameBody::Data { offset, bytes } => (offset, bytes),
            FrameBody::End(_) => return self.close(id),
            FrameBody::Credit { direction, bytes } => {
                self.pump();
                let stream = self.streams.get_mut(&id);
                // An ending stream still needs credit for its last output.
                let stream = stream.filter(|s| matches!(s.status, Status::Open | Status::Ending));
                let stream = stream.ok_or_else(BackendError::not_open)?;
                match direction {
                    Direction::Out => stream.grant(bytes),
                    // Only this backend grants `in` credit.
                    Direction::In => stream.violate(Lost::new("credit direction", false)),
                }
                if stream.status == Status::Ended {
                    self.release(id);
                }
                return Ok(());
            }
        };
        self.write(id, offset, bytes)
    }

    /// Closes the terminal for the session host. Output not taken yet is
    /// dropped; input already written stays written.
    fn close(&mut self, id: StreamId) -> Result<(), BackendError> {
        self.pump();
        let Some(stream) = self.streams.get_mut(&id) else {
            return Err(BackendError::not_open());
        };
        if stream.status == Status::Closed {
            return Err(BackendError::not_open());
        }
        stream.close();
        self.release(id);
        Ok(())
    }
}

fn lock(inner: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
    // A panic while holding the lock leaves plain data; keep serving.
    inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

pub struct RescueBackend {
    id: BackendId,
    kinds: Vec<LocalId>,
    inner: Arc<Mutex<Inner>>,
}

impl RescueBackend {
    pub fn new(transport: Box<dyn RescueTransport>) -> Self {
        let kind = LocalId::new(RESCUE_KIND).expect("valid kind");
        let id = BackendId::app("cmux/cloud", &LocalId::new(RESCUE_ID).expect("valid id"));
        let kinds = vec![kind];
        check_kinds(&kinds).expect("valid kinds");
        Self {
            id,
            kinds,
            inner: Arc::new(Mutex::new(Inner { transport, streams: HashMap::new() })),
        }
    }

    /// Whether the transport can open streams (false: no Cloud API route).
    pub fn available(&self) -> bool {
        lock(&self.inner).transport.available()
    }
}

impl TerminalBackend for RescueBackend {
    fn id(&self) -> &BackendId {
        &self.id
    }

    fn kinds(&self) -> &[LocalId] {
        &self.kinds
    }

    fn capabilities(&self) -> BackendCapabilities {
        BackendCapabilities {
            resize: true,
            signals: true,
            exit_status: true,
            resume: false,
            cwd_reports: false,
            max_write_bytes: MAX_WRITE_BYTES as u32,
            // A login shell over a byte stream: the session host answers
            // DA, DSR and OSC color queries.
            answers_queries: false,
        }
    }

    fn open(&mut self, request: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError> {
        allow_kind(&self.kinds, &request.kind)?;
        request.open_token.check()?;
        if request.command.is_some() {
            // The rescue shell runs the machine's login shell only.
            return Err(BackendError::Unsupported);
        }
        let mut inner = lock(&self.inner);
        let stream = inner.transport.open(&request.target, request.grid)?;
        inner.streams.insert(stream, Stream::new(DEFAULT_WINDOW_BYTES));
        Ok(Box::new(RescueTerminal { inner: Arc::clone(&self.inner), stream }))
    }

    fn resume(&mut self, _request: ResumeRequest) -> Result<Resumed, BackendError> {
        // Capability `resume: false`: a rescue shell cannot be resumed.
        Err(BackendError::Unsupported)
    }
}

struct RescueTerminal {
    inner: Arc<Mutex<Inner>>,
    stream: StreamId,
}

impl ByteTerminal for RescueTerminal {
    fn window_bytes(&self) -> u32 {
        DEFAULT_WINDOW_BYTES
    }

    fn push(&mut self, frame: FrameBody) -> Result<(), BackendError> {
        lock(&self.inner).push(self.stream, frame)
    }

    fn take_frames(&mut self) -> Vec<FrameBody> {
        let mut inner = lock(&self.inner);
        inner.pump();
        inner.streams.get_mut(&self.stream).map(Stream::take).unwrap_or_default()
    }

    fn resize(&mut self, grid: Grid) -> Result<(), BackendError> {
        if grid.cols == 0 || grid.rows == 0 {
            return Err(BackendError::invalid("a grid needs at least one column and row"));
        }
        let mut inner = lock(&self.inner);
        inner.open_stream(self.stream)?;
        // A refused resize leaves the shell running (as in the sample): the
        // error is the answer, the terminal stays open.
        inner.transport.resize(self.stream, grid)
    }

    fn signal(&mut self, signal: Signal) -> Result<(), BackendError> {
        let mut inner = lock(&self.inner);
        inner.open_stream(self.stream)?;
        // A refused signal leaves the shell running, like a refused resize.
        inner.transport.signal(self.stream, signal)
    }

    fn close(&mut self, _how: Close) -> Result<(), BackendError> {
        lock(&self.inner).close(self.stream)
    }

    fn resume_token(&self) -> Option<ResumeToken> {
        None
    }
}

impl Drop for RescueTerminal {
    fn drop(&mut self) {
        let mut inner = lock(&self.inner);
        if let Some(stream) = inner.streams.remove(&self.stream)
            && !stream.released
        {
            // The session host dropped the terminal: end the far shell.
            let _refused = inner.transport.close(self.stream);
        }
    }
}
