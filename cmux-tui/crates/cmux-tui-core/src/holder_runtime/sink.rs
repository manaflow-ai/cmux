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
    /// No holder streams this terminal any more (a holder restart failed).
    lost: bool,
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

    /// Bytes the parser reads before the holder's (an archived terminal's
    /// replay); they take no holder offset.
    pub(crate) fn prepend(&self, seed: &[u8]) {
        let mut state = self.state.lock().recover_poison();
        for byte in seed.iter().rev() {
            state.bytes.push_front(*byte);
        }
    }

    /// Wait (at most `limit`) until the reader took every queued byte.
    pub(crate) fn wait_drained(&self, limit: std::time::Duration) {
        let deadline = std::time::Instant::now() + limit;
        let mut state = self.state.lock().recover_poison();
        while !state.bytes.is_empty() && !state.detached {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                return;
            }
            state = self.changed.wait_timeout(state, left).recover_poison().0;
        }
    }

    /// The holder is gone for good: the reader drains and the wait ends lost.
    pub(crate) fn lose(&self) {
        self.state.lock().recover_poison().lost = true;
        self.changed.notify_all();
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
        while state.bytes.is_empty() && state.exit.is_none() && !state.detached && !state.lost {
            state = self.changed.wait(state).recover_poison();
        }
        if state.detached {
            return 0;
        }
        let n = buf.len().min(state.bytes.len());
        for (slot, byte) in buf.iter_mut().zip(state.bytes.drain(..n)) {
            *slot = byte;
        }
        if state.bytes.is_empty() {
            drop(state);
            // A re-adoption waits for the queue to drain (`wait_drained`).
            self.changed.notify_all();
        }
        n
    }

    /// Block until the terminal ended, was lost or the daemon detached.
    pub(crate) fn wait_end(&self) -> SinkEnd {
        let mut state = self.state.lock().recover_poison();
        while state.exit.is_none() && !state.detached && !state.lost {
            state = self.changed.wait(state).recover_poison();
        }
        match (state.detached, state.exit) {
            (true, _) => SinkEnd::Detached,
            (false, Some(status)) => SinkEnd::Exited(status),
            (false, None) => SinkEnd::Lost,
        }
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

    fn prologue(&self, bytes: &[u8]) {
        self.state.lock().recover_poison().bytes.extend(bytes);
        self.changed.notify_all();
    }

    fn exit(&self, status: ExitStatus, _end: u64) {
        self.state.lock().recover_poison().exit = Some(status);
        self.changed.notify_all();
    }
}

/// How a holder terminal's stream ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SinkEnd {
    /// The shell ended; the holder reported its status.
    Exited(ExitStatus),
    /// No holder could stream it any more.
    Lost,
    /// The daemon left it running for its shutdown.
    Detached,
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
        assert_eq!(sink.wait_end(), SinkEnd::Exited(ExitStatus::Exited(0)));
    }

    #[test]
    fn a_seed_comes_first_and_a_lost_holder_ends_the_stream() {
        let sink = HolderSink::new(0);
        sink.data(0, b"shell");
        sink.prepend(b"seed:");
        sink.lose();
        let mut out = Vec::new();
        SinkReader(sink.clone()).read_to_end(&mut out).unwrap();
        assert_eq!(out, b"seed:shell");
        assert_eq!(sink.received(), 5);
        assert_eq!(sink.wait_end(), SinkEnd::Lost);
    }

    #[test]
    fn a_detach_ends_the_reader_and_the_wait_without_an_end() {
        let sink = HolderSink::new(0);
        sink.data(0, b"kept by the holder");
        sink.detach();
        let mut buf = [0u8; 8];
        assert_eq!(SinkReader(sink.clone()).read(&mut buf).unwrap(), 0);
        assert_eq!(sink.wait_end(), SinkEnd::Detached);
    }
}
