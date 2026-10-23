//! One holder terminal's output queue on the daemon side.

use std::collections::VecDeque;
use std::io::{self, Read};
use std::sync::{Arc, Condvar, Mutex};

use cmux_holder::ExitStatus;
use cmux_holder::link::TerminalSink;

use crate::panic_free::RecoverPoison;

#[derive(Default)]
struct SinkState {
    bytes: VecDeque<u8>,
    /// Offset after the newest byte received (the holder's numbering).
    received: u64,
    exit: Option<ExitStatus>,
    /// The daemon is shutting down and leaves the terminal running.
    detached: bool,
}

/// Bytes the holder streamed for one terminal, waiting for the terminal's
/// reader thread, and the terminal's end. Unbounded: the holder sends at
/// most one link queue (1 MiB) ahead of what the daemon reads, and the
/// reader parses faster than a PTY fills.
pub(crate) struct HolderSink {
    state: Mutex<SinkState>,
    changed: Condvar,
}

impl HolderSink {
    /// A sink whose next byte has offset `base`.
    pub(crate) fn new(base: u64) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(SinkState { received: base, ..SinkState::default() }),
            changed: Condvar::new(),
        })
    }

    /// Offset after the newest byte received: where a new holder resumes.
    pub(crate) fn received(&self) -> u64 {
        self.state.lock().recover_poison().received
    }

    /// End the reader and the wait without an end of the terminal: the
    /// daemon exits and the holder keeps the shell.
    pub(crate) fn detach(&self) {
        self.state.lock().recover_poison().detached = true;
        self.changed.notify_all();
    }

    pub(crate) fn is_detached(&self) -> bool {
        self.state.lock().recover_poison().detached
    }

    /// Up to `buf.len()` bytes; 0 once the terminal ended (or the daemon
    /// detached) and every byte before was read.
    fn read(&self, buf: &mut [u8]) -> usize {
        let mut state = self.state.lock().recover_poison();
        while state.bytes.is_empty() && state.exit.is_none() && !state.detached {
            state = self.changed.wait(state).recover_poison();
        }
        if state.detached {
            return 0;
        }
        let n = buf.len().min(state.bytes.len());
        for (slot, byte) in buf.iter_mut().zip(state.bytes.drain(..n)) {
            *slot = byte;
        }
        n
    }

    /// Block until the terminal ended (`Some`) or the daemon detached (`None`).
    pub(crate) fn wait_end(&self) -> Option<ExitStatus> {
        let mut state = self.state.lock().recover_poison();
        while state.exit.is_none() && !state.detached {
            state = self.changed.wait(state).recover_poison();
        }
        if state.detached { None } else { state.exit }
    }
}

impl TerminalSink for HolderSink {
    fn data(&self, offset: u64, bytes: &[u8]) {
        let mut state = self.state.lock().recover_poison();
        let end = offset + bytes.len() as u64;
        if end <= state.received {
            // A new holder resent bytes this sink already has.
            return;
        }
        let skip = state.received.saturating_sub(offset) as usize;
        state.bytes.extend(&bytes[skip.min(bytes.len())..]);
        state.received = end;
        drop(state);
        self.changed.notify_all();
    }

    fn gap(&self, requested: u64, oldest: u64) {
        eprintln!("cmux-tui: holder terminal lost output {requested}..{oldest}");
        let mut state = self.state.lock().recover_poison();
        state.received = state.received.max(oldest);
    }

    fn exit(&self, status: ExitStatus, _end: u64) {
        self.state.lock().recover_poison().exit = Some(status);
        self.changed.notify_all();
    }
}

/// The terminal reader's view of a [`HolderSink`].
pub(super) struct SinkReader(pub(super) Arc<HolderSink>);

impl Read for SinkReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        Ok(self.0.read(buf))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resent_bytes_are_dropped_and_the_end_follows_the_last_byte() {
        let sink = HolderSink::new(10);
        sink.data(10, b"abc");
        sink.data(11, b"bcde");
        sink.exit(ExitStatus::Exited(0), 15);
        let mut reader = SinkReader(sink.clone());
        let mut out = Vec::new();
        reader.read_to_end(&mut out).unwrap();
        assert_eq!(out, b"abcde");
        assert_eq!(sink.received(), 15);
        assert_eq!(sink.wait_end(), Some(ExitStatus::Exited(0)));
    }

    #[test]
    fn a_detach_ends_the_reader_and_the_wait_without_an_end() {
        let sink = HolderSink::new(0);
        sink.data(0, b"kept by the holder");
        sink.detach();
        let mut buf = [0u8; 8];
        assert_eq!(SinkReader(sink.clone()).read(&mut buf).unwrap(), 0);
        assert_eq!(sink.wait_end(), None);
    }
}
