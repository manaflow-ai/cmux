//! [`RescueBackend`]: `cmux.terminal.backend/1` for kind `cloud-vm-rescue`.
//!
//! The local session host owns the VT state, history and snapshots; this
//! backend only moves bytes between it and a [`RescueTransport`] stream.
//! It is the only writer of each rescue terminal's stream state. The rules
//! follow the SSH sample's session (and its conformance vectors): input in
//! `seq` order, each `seq` once; output offsets are the running byte total;
//! one end event (`exit` or `lost`), then nothing; after `close` every call
//! is refused and nothing queues.

use super::iface::{
    BackendCapabilities, BackendError, BackendId, ByteEvent, ByteTerminal, Close, ExitStatus, Grid,
    Input, LocalId, MAX_EXIT_MESSAGE, OpenRequest, ResumeRequest, ResumeToken, Resumed, Signal,
    TerminalBackend, allow_kind, check_kinds,
};
use super::transport::{RescueTransport, StreamId, TransportEvent};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, MutexGuard};

pub const RESCUE_KIND: &str = "cloud-vm-rescue";
pub const RESCUE_ID: &str = "rescue";

/// Input chunks held while an earlier `seq` is missing. More is refused.
const MAX_PENDING_INPUT: usize = 256;
/// One write to the transport at most (a paste is split by the session host).
const MAX_WRITE_BYTES: usize = 64 * 1024;
/// Longest signal name kept from the far end (`exit.signal`).
const MAX_SIGNAL_NAME: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Status {
    Open,
    /// The end event (`exit` or `lost`) is queued or was taken.
    Ended,
    /// The session host closed the terminal: nothing more is delivered.
    Closed,
}

struct Stream {
    status: Status,
    next_seq: u64,
    pending: BTreeMap<u64, Vec<u8>>,
    events: Vec<ByteEvent>,
    /// Output bytes since open (the `offset` of the last output event).
    offset: u64,
    /// The transport stream is closed or gone: never close it again.
    released: bool,
}

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

impl Stream {
    /// Queues the one end event and drops held input.
    fn end(&mut self, event: ByteEvent) {
        self.status = Status::Ended;
        self.released = true;
        self.pending.clear();
        self.events.push(event);
    }
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
                TransportEvent::Output(bytes) if bytes.is_empty() => {}
                TransportEvent::Output(bytes) => {
                    stream.offset += bytes.len() as u64;
                    stream.events.push(ByteEvent::Output { offset: stream.offset, bytes });
                }
                TransportEvent::Closed(status) => stream.end(ByteEvent::Exit(bounded(status))),
                TransportEvent::Dropped { mut reason, retryable } => {
                    cut(&mut reason, MAX_EXIT_MESSAGE);
                    stream.end(ByteEvent::Lost { reason, retryable });
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

    /// A transport failure ends the stream: the terminal shows it lost.
    fn fail(&mut self, id: StreamId, error: BackendError) -> BackendError {
        if let Some(stream) = self.streams.get_mut(&id)
            && stream.status == Status::Open
        {
            let retryable = matches!(error, BackendError::Unavailable { retryable: true, .. });
            let mut reason = error.to_string();
            cut(&mut reason, MAX_EXIT_MESSAGE);
            stream.end(ByteEvent::Lost { reason, retryable });
        }
        error
    }

    fn write(&mut self, id: StreamId, input: Input) -> Result<(), BackendError> {
        if input.bytes.len() > MAX_WRITE_BYTES {
            return Err(BackendError::invalid(format!(
                "one write carries at most {MAX_WRITE_BYTES} bytes"
            )));
        }
        let stream = self.open_stream(id)?;
        let next = stream.next_seq;
        if input.seq < next || stream.pending.contains_key(&input.seq) {
            return Err(BackendError::invalid(format!("seq {} was already written", input.seq)));
        }
        if input.seq - next > MAX_PENDING_INPUT as u64 {
            return Err(BackendError::invalid(format!(
                "seq {} is more than {MAX_PENDING_INPUT} ahead of {next}",
                input.seq
            )));
        }
        stream.pending.insert(input.seq, input.bytes);
        let mut ready = Vec::new();
        while let Some(bytes) = stream.pending.remove(&stream.next_seq) {
            ready.push(bytes);
            stream.next_seq += 1;
        }
        for bytes in ready {
            if let Err(error) = self.transport.write(id, &bytes) {
                return Err(self.fail(id, error));
            }
        }
        Ok(())
    }

    /// Closes the terminal for the session host. Held input (waiting for an
    /// earlier `seq`) was never accepted in order, so it is dropped for
    /// either `Close`; in-order input already went to the transport.
    fn close(&mut self, id: StreamId) -> Result<(), BackendError> {
        self.pump();
        let Some(stream) = self.streams.get_mut(&id) else {
            return Err(BackendError::not_open());
        };
        if stream.status == Status::Closed {
            return Err(BackendError::not_open());
        }
        stream.status = Status::Closed;
        stream.pending.clear();
        stream.events.clear();
        if !std::mem::replace(&mut stream.released, true) {
            // The stream is gone for the session host either way.
            let _refused = self.transport.close(id);
        }
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
        if request.command.is_some() {
            // The rescue shell runs the machine's login shell only.
            return Err(BackendError::Unsupported);
        }
        let mut inner = lock(&self.inner);
        let stream = inner.transport.open(&request.target, request.grid)?;
        inner.streams.insert(
            stream,
            Stream {
                status: Status::Open,
                next_seq: 0,
                pending: BTreeMap::new(),
                events: Vec::new(),
                offset: 0,
                released: false,
            },
        );
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
    fn take_events(&mut self) -> Vec<ByteEvent> {
        let mut inner = lock(&self.inner);
        inner.pump();
        inner
            .streams
            .get_mut(&self.stream)
            .map(|s| std::mem::take(&mut s.events))
            .unwrap_or_default()
    }

    fn write(&self, input: Input) -> Result<(), BackendError> {
        lock(&self.inner).write(self.stream, input)
    }

    fn resize(&self, grid: Grid) -> Result<(), BackendError> {
        if grid.cols == 0 || grid.rows == 0 {
            return Err(BackendError::invalid("a grid needs at least one column and row"));
        }
        let mut inner = lock(&self.inner);
        inner.open_stream(self.stream)?;
        inner.transport.resize(self.stream, grid).map_err(|e| inner.fail(self.stream, e))
    }

    fn signal(&self, signal: Signal) -> Result<(), BackendError> {
        let mut inner = lock(&self.inner);
        inner.open_stream(self.stream)?;
        inner.transport.signal(self.stream, signal).map_err(|e| inner.fail(self.stream, e))
    }

    fn close(&self, _how: Close) -> Result<(), BackendError> {
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
