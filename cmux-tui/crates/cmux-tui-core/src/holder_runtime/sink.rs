//! One holder terminal's output queue on the daemon side.

use std::collections::VecDeque;
use std::io::{self, Read};
use std::sync::{Arc, Condvar, Mutex, OnceLock};

use cmux_holder::ExitStatus;
use cmux_holder::link::TerminalSink;
use cmux_holder::wire::ACK_EVERY;

use crate::panic_free::RecoverPoison;

#[derive(Default)]
struct SinkState {
    bytes: VecDeque<u8>,
    /// Bytes at the front of `bytes` that carry no holder offset (a reopen
    /// seed, a prologue). Never more than there are: an uncounted one only
    /// delays an acknowledgement until the queue drains.
    unnumbered: usize,
    /// Offset after the newest byte received (the holder's numbering).
    received: u64,
    /// Offset last acknowledged to the holder.
    acked: u64,
    /// Offset of the newest screen snapshot handed to the holder.
    snapshot_base: u64,
    exit: Option<ExitStatus>,
    /// No holder streams this terminal any more (a holder restart failed).
    lost: bool,
    /// The daemon is shutting down and leaves the terminal running.
    detached: bool,
}

/// Bytes the holder streamed for one terminal, waiting for the terminal's
/// reader thread, and the terminal's end. Bounded by credit: the sink
/// acknowledges what the parser read (every `ACK_EVERY` bytes), and the
/// holder sends at most `CREDIT_WINDOW` past the last acknowledgement, so a
/// terminal that prints faster than the daemon parses waits in its PTY
/// instead of growing this queue.
pub(crate) struct HolderSink {
    state: Mutex<SinkState>,
    changed: Condvar,
    /// Sends an acknowledgement to the current holder (set once the
    /// terminal has a channel).
    acker: OnceLock<Acker>,
}

/// Acknowledges to the holder that the parser read every byte before an
/// offset.
pub(crate) type Acker = Box<dyn Fn(u64) + Send + Sync>;

impl SinkState {
    /// Offset after the last byte the parser read.
    fn parsed(&self) -> u64 {
        let numbered = self.bytes.len() - self.unnumbered.min(self.bytes.len());
        self.received.saturating_sub(numbered as u64)
    }
}

impl HolderSink {
    /// A sink whose next byte has offset `base`.
    pub(crate) fn new(base: u64) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(SinkState {
                received: base,
                acked: base,
                snapshot_base: base,
                ..SinkState::default()
            }),
            changed: Condvar::new(),
            acker: OnceLock::new(),
        })
    }

    /// Acknowledge through `acker` from now on, starting with what the
    /// parser already read: the holder may be waiting for it.
    pub(crate) fn set_acker(&self, acker: Acker) {
        if self.acker.set(acker).is_err() {
            return;
        }
        let parsed = {
            let mut state = self.state.lock().recover_poison();
            let parsed = state.parsed();
            state.acked = state.acked.max(parsed);
            parsed
        };
        if let Some(acker) = self.acker.get() {
            acker(parsed);
        }
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
        state.unnumbered += seed.len();
    }

    /// The offset to snapshot the screen at now, if one is due: called by
    /// the terminal's reader before it reads again, when the parser has
    /// parsed every byte it was handed, so the screen is exactly the screen
    /// at that offset. Due once the stream went idle with
    /// [`SNAPSHOT_IDLE_BYTES`] parsed since the last snapshot, or after
    /// [`SNAPSHOT_EVERY_BYTES`] even while output keeps coming. None while
    /// unnumbered bytes (a seed, a prologue) wait: the screen is not the
    /// screen at any offset until they are parsed.
    pub(super) fn snapshot_due(&self) -> Option<u64> {
        let state = self.state.lock().recover_poison();
        if state.unnumbered > 0 || state.detached || state.lost || state.exit.is_some() {
            return None;
        }
        let parsed = state.parsed();
        let since = parsed.saturating_sub(state.snapshot_base);
        let idle = state.bytes.is_empty();
        ((idle && since >= SNAPSHOT_IDLE_BYTES) || since >= SNAPSHOT_EVERY_BYTES).then_some(parsed)
    }

    /// A snapshot at `base` went to the holder (or could not be made).
    pub(super) fn snapshot_taken(&self, base: u64) {
        let mut state = self.state.lock().recover_poison();
        state.snapshot_base = state.snapshot_base.max(base);
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
        let (head, tail) = state.bytes.as_slices();
        let from_head = n.min(head.len());
        buf[..from_head].copy_from_slice(&head[..from_head]);
        buf[from_head..n].copy_from_slice(&tail[..n - from_head]);
        state.bytes.drain(..n);
        state.unnumbered = state.unnumbered.saturating_sub(n);
        let parsed = state.parsed();
        let ack = (parsed >= state.acked + ACK_EVERY && self.acker.get().is_some()).then(|| {
            state.acked = parsed;
            parsed
        });
        let drained = state.bytes.is_empty();
        drop(state);
        if drained {
            // A re-adoption waits for the queue to drain (`wait_drained`).
            self.changed.notify_all();
        }
        if let (Some(offset), Some(acker)) = (ack, self.acker.get()) {
            acker(offset);
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

/// CAN: ends an escape sequence the parser is inside, so output after a
/// gap does not continue a sequence (or a UTF-8 character) cut by it.
pub(super) const CANCEL: u8 = 0x18;

/// A stream that went idle gets a fresh screen snapshot once this much
/// output was parsed since the last one: a prompt redraw or an echo never
/// costs a replay, a burst of TUI output does once.
pub(super) const SNAPSHOT_IDLE_BYTES: u64 = 64 * 1024;
/// Output parsed between two snapshots while it never goes idle (a flood):
/// the holder's prologue then is at most this far behind the stream.
pub(super) const SNAPSHOT_EVERY_BYTES: u64 = 2 * 1024 * 1024;

impl SinkState {
    /// Queue bytes that take no holder offset behind what is queued.
    fn push_unnumbered(&mut self, bytes: &[u8]) {
        if self.unnumbered == self.bytes.len() {
            self.unnumbered += bytes.len();
        }
        self.bytes.extend(bytes);
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
        if offset > state.received {
            // Bytes missing before these: never splice them silently.
            eprintln!("cmux-tui: holder terminal lost output {}..{offset}", state.received);
            state.bytes.push_back(CANCEL);
        }
        let skip = state.received.saturating_sub(offset) as usize;
        state.bytes.extend(&bytes[skip.min(bytes.len())..]);
        state.received = end;
        drop(state);
        self.changed.notify_all();
    }

    fn gap(&self, requested: u64, oldest: u64) {
        let mut state = self.state.lock().recover_poison();
        if oldest > state.received {
            eprintln!("cmux-tui: holder terminal lost output {requested}..{oldest}");
            state.received = oldest;
            state.bytes.push_back(CANCEL);
            drop(state);
            self.changed.notify_all();
        }
    }

    fn prologue(&self, base: u64, bytes: &[u8]) {
        let mut state = self.state.lock().recover_poison();
        state.push_unnumbered(bytes);
        if base < state.received {
            // A snapshot older than the holder's ring: the output between
            // is gone, and the next byte may be inside a sequence.
            state.push_unnumbered(&[CANCEL]);
        } else {
            state.received = base;
        }
        state.snapshot_base = state.snapshot_base.max(base);
        drop(state);
        self.changed.notify_all();
    }

    fn acks_itself(&self) -> bool {
        true
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

/// A plain reader's view of a [`HolderSink`] (the tests' parser).
#[cfg(test)]
pub(super) struct SinkReader(pub(super) Arc<HolderSink>);

#[cfg(test)]
impl Read for SinkReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        Ok(self.0.read(buf))
    }
}

/// [`SinkReader`] for a terminal on the holder: before each read, while
/// the parser has parsed every byte it was handed, it hands the holder a
/// due screen snapshot ([`HolderSink::snapshot_due`]), so a restarted
/// daemon restores modes, alternate screen, title and directory however
/// much the terminal printed since they were set.
pub(super) struct SnapshottingReader {
    pub(super) sink: Arc<HolderSink>,
    /// Builds and sends the snapshot at an offset (the terminal's replay).
    pub(super) snapshot: Box<dyn Fn(u64) + Send>,
}

impl Read for SnapshottingReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if let Some(base) = self.sink.snapshot_due() {
            (self.snapshot)(base);
            self.sink.snapshot_taken(base);
        }
        Ok(self.sink.read(buf))
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
    fn the_sink_acknowledges_what_the_parser_read_so_the_holder_sends_more() {
        let acks = Arc::new(Mutex::new(Vec::new()));
        let sink = HolderSink::new(0);
        sink.prepend(b"seed");
        let chunk = vec![b'a'; 100 * 1024];
        sink.data(0, &chunk);
        sink.data(chunk.len() as u64, &chunk);
        let recorded = acks.clone();
        sink.set_acker(Box::new(move |offset| recorded.lock().unwrap().push(offset)));
        // Nothing parsed yet: the first acknowledgement is the base.
        assert_eq!(*acks.lock().unwrap(), vec![0]);
        let mut reader = SinkReader(sink.clone());
        let mut buf = vec![0u8; 64 * 1024];
        let mut read = 0;
        while read < 4 + 2 * chunk.len() {
            read += reader.read(&mut buf).unwrap();
        }
        let acks = acks.lock().unwrap().clone();
        let last = *acks.last().unwrap();
        // The seed takes no holder offset: what the parser read of the
        // holder's bytes is acknowledged, every ACK_EVERY bytes.
        assert!(acks.len() >= 2, "{acks:?}");
        assert!(last >= ACK_EVERY && last <= 2 * chunk.len() as u64, "{acks:?}");
    }

    #[test]
    fn missing_bytes_are_cancelled_not_spliced() {
        let sink = HolderSink::new(0);
        sink.data(0, b"\x1b[3");
        sink.data(10, b"1mx");
        sink.gap(13, 20);
        sink.data(20, b"y");
        sink.exit(ExitStatus::Exited(0), 21);
        let mut out = Vec::new();
        SinkReader(sink.clone()).read_to_end(&mut out).unwrap();
        assert_eq!(out, b"\x1b[3\x181mx\x18y");
        assert_eq!(sink.received(), 21);
    }

    #[test]
    fn a_snapshot_is_due_after_a_burst_once_the_stream_is_idle() {
        let sink = HolderSink::new(0);
        let burst = vec![b'a'; SNAPSHOT_IDLE_BYTES as usize];
        sink.data(0, &burst);
        // Queued, not parsed: the screen is not the screen at any offset yet.
        assert_eq!(sink.snapshot_due(), None);
        let mut buf = vec![0u8; burst.len()];
        let mut reader = SinkReader(sink.clone());
        let mut read = 0;
        while read < burst.len() {
            read += reader.read(&mut buf).unwrap();
        }
        assert_eq!(sink.snapshot_due(), Some(burst.len() as u64));
        sink.snapshot_taken(burst.len() as u64);
        // An echo after it costs no replay.
        sink.data(burst.len() as u64, b"x");
        assert_eq!(reader.read(&mut buf).unwrap(), 1);
        assert_eq!(sink.snapshot_due(), None);
    }

    #[test]
    fn a_prologue_older_than_the_ring_is_followed_by_a_cancel() {
        let sink = HolderSink::new(100);
        sink.prologue(40, b"<screen>");
        sink.data(100, b"tail");
        sink.exit(ExitStatus::Exited(0), 104);
        let mut out = Vec::new();
        SinkReader(sink.clone()).read_to_end(&mut out).unwrap();
        assert_eq!(out, b"<screen>\x18tail");
        // A current prologue sets where the stream continues.
        let sink = HolderSink::new(100);
        sink.prologue(150, b"<screen>");
        sink.data(150, b"tail");
        assert_eq!(sink.received(), 154);
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
