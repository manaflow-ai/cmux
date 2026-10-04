//! [`RescueBackend`]: `cmux.terminal.backend/1` for kind `cloud-vm-rescue`.
//!
//! The local session host owns the VT state, history and snapshots; this
//! backend only moves bytes between it and a [`RescueTransport`] stream.
//! It is the only writer of each rescue terminal's stream state.

use super::iface::{
    BackendCapabilities, BackendError, BackendId, ByteEvent, ByteTerminal, Close, ExitStatus, Grid,
    Input, LocalId, OpenRequest, ResumeToken, Signal, TerminalBackend,
};
use super::transport::{RescueTransport, StreamId, TransportEvent};
use crate::connector::iface::{allow_kind, check_kinds};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, MutexGuard};

pub const RESCUE_KIND: &str = "cloud-vm-rescue";
pub const RESCUE_ID: &str = "rescue";

/// Input chunks held while an earlier `seq` is missing. More is refused.
const MAX_PENDING_INPUT: usize = 256;
/// One write to the transport at most (a paste is split by the session host).
const MAX_WRITE_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
enum Status {
    Open,
    Exited,
    Lost,
}

struct Stream {
    status: Status,
    next_seq: u64,
    pending: BTreeMap<u64, Vec<u8>>,
    events: Vec<ByteEvent>,
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
                TransportEvent::Output(bytes) => stream.events.push(ByteEvent::Output(bytes)),
                TransportEvent::Closed { code } => {
                    stream.status = Status::Exited;
                    stream.pending.clear();
                    stream.events.push(ByteEvent::Exit(ExitStatus { code }));
                }
                TransportEvent::Dropped { reason } => {
                    stream.status = Status::Lost;
                    stream.pending.clear();
                    stream.events.push(ByteEvent::Lost(reason));
                }
            }
        }
    }

    fn open_stream(&mut self, id: StreamId) -> Result<&mut Stream, BackendError> {
        self.pump();
        match self.streams.get_mut(&id) {
            Some(stream) if stream.status == Status::Open => Ok(stream),
            _ => Err(BackendError::Closed),
        }
    }

    /// A transport failure ends the stream: the terminal shows it lost.
    fn fail(&mut self, id: StreamId, error: BackendError) -> BackendError {
        if let Some(stream) = self.streams.get_mut(&id)
            && stream.status == Status::Open
        {
            stream.status = Status::Lost;
            stream.pending.clear();
            stream.events.push(ByteEvent::Lost(error.to_string()));
        }
        error
    }

    fn write(&mut self, id: StreamId, input: Input) -> Result<(), BackendError> {
        if input.bytes.len() > MAX_WRITE_BYTES {
            return Err(BackendError::Invalid(format!(
                "one write carries at most {MAX_WRITE_BYTES} bytes"
            )));
        }
        let stream = self.open_stream(id)?;
        if input.seq < stream.next_seq || stream.pending.contains_key(&input.seq) {
            // A replay of a chunk already accepted: no further effect.
            return Ok(());
        }
        if input.seq > stream.next_seq {
            if stream.pending.len() >= MAX_PENDING_INPUT {
                return Err(BackendError::Invalid(format!(
                    "input seq {} is too far ahead of {}",
                    input.seq, stream.next_seq
                )));
            }
            stream.pending.insert(input.seq, input.bytes);
            return Ok(());
        }
        let mut ready = vec![input.bytes];
        stream.next_seq += 1;
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
            max_write_bytes: MAX_WRITE_BYTES,
        }
    }

    fn open(&mut self, request: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError> {
        allow_kind(&self.kinds, &request.kind)?;
        if request.command.is_some() {
            return Err(BackendError::Unsupported(
                "the rescue shell runs the machine's login shell only".into(),
            ));
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
            },
        );
        Ok(Box::new(RescueTerminal { inner: Arc::clone(&self.inner), stream }))
    }

    fn resume(&mut self, _token: &ResumeToken) -> Result<Box<dyn ByteTerminal>, BackendError> {
        Err(BackendError::Unsupported("a rescue shell cannot be resumed".into()))
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
            return Err(BackendError::Invalid("a grid needs at least one column and row".into()));
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
        let mut inner = lock(&self.inner);
        inner.open_stream(self.stream)?;
        // The exit arrives as a transport event; nothing more is written.
        if let Some(stream) = inner.streams.get_mut(&self.stream) {
            stream.pending.clear();
        }
        inner.transport.close(self.stream).map_err(|e| inner.fail(self.stream, e))
    }

    fn resume_token(&self) -> Option<ResumeToken> {
        None
    }
}

impl Drop for RescueTerminal {
    fn drop(&mut self) {
        let mut inner = lock(&self.inner);
        if inner.streams.get(&self.stream).is_some_and(|s| s.status == Status::Open) {
            // Best effort: the session host dropped the terminal.
            let _ = inner.transport.close(self.stream);
        }
        inner.streams.remove(&self.stream);
    }
}
