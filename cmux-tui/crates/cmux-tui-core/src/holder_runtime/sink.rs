//! One holder terminal's output queue on the daemon side.

use std::collections::VecDeque;
use std::io::{self, Read};
use std::sync::{Arc, Condvar, Mutex, OnceLock};

use cmux_holder::ExitStatus;
use cmux_holder::link::TerminalSink;
use cmux_holder::wire::ACK_EVERY;

use crate::panic_free::RecoverPoison;

/// A run of queued bytes: holder output from `offset` on, or bytes that
/// take no holder offset (`None`: a reopen seed, a prologue, a CAN for a
/// gap).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Run {
    len: usize,
    offset: Option<u64>,
}

#[derive(Default)]
struct SinkState {
    /// Bytes for the parser, in order. The first `in_flight` of them were
    /// handed to the reader, which has not finished parsing them.
    bytes: VecDeque<u8>,
    /// `bytes` as runs, so each byte's holder offset (or none) is known.
    runs: VecDeque<Run>,
    in_flight: usize,
    /// Offset after the newest byte received (the holder's numbering).
    received: u64,
    /// Offset after the last holder byte the parser finished parsing: the
    /// screen is exactly the output up to here (plus the unnumbered bytes
    /// parsed before it). Acknowledgements, snapshots and a hand-off to a
    /// new holder all start here, never at `received`.
    confirmed: u64,
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
/// acknowledges what the parser parsed (every `ACK_EVERY` bytes), and the
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

/// What the parser has not finished parsing, at one instant: the bytes a
/// new holder's prologue must carry (`crate::holder_runtime` re-adoption).
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Pending {
    /// [`HolderSink`]'s confirmed offset: the screen is the output up to it.
    pub(crate) confirmed: u64,
    /// The offset after the newest byte received.
    pub(crate) received: u64,
    /// The unnumbered bytes before the first holder byte not parsed yet (a
    /// seed the parser has not finished).
    pub(crate) head: Vec<u8>,
    /// Every byte not parsed yet, in order.
    pub(crate) all: Vec<u8>,
}

impl SinkState {
    fn push_numbered(&mut self, offset: u64, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.bytes.extend(bytes);
        match self.runs.back_mut() {
            Some(Run { len, offset: Some(start) }) if *start + *len as u64 == offset => {
                *len += bytes.len();
            }
            _ => self.runs.push_back(Run { len: bytes.len(), offset: Some(offset) }),
        }
    }

    fn push_unnumbered(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.bytes.extend(bytes);
        match self.runs.back_mut() {
            Some(Run { len, offset: None }) => *len += bytes.len(),
            _ => self.runs.push_back(Run { len: bytes.len(), offset: None }),
        }
    }

    /// The reader finished parsing what it took: drop it from the queue
    /// and move the confirmed offset past its last holder byte.
    fn confirm(&mut self) {
        let mut left = std::mem::take(&mut self.in_flight);
        self.bytes.drain(..left.min(self.bytes.len()));
        while left > 0 {
            let Some(run) = self.runs.front_mut() else { break };
            let n = left.min(run.len);
            if let Some(offset) = run.offset.as_mut() {
                *offset += n as u64;
                self.confirmed = *offset;
            }
            run.len -= n;
            left -= n;
            if run.len == 0 {
                self.runs.pop_front();
            }
        }
    }

    /// An acknowledgement is due for what the parser confirmed.
    fn due_ack(&mut self, can_ack: bool) -> Option<u64> {
        (can_ack && self.confirmed >= self.acked + ACK_EVERY).then(|| {
            self.acked = self.confirmed;
            self.confirmed
        })
    }

    fn has_unnumbered(&self) -> bool {
        self.runs.iter().any(|run| run.offset.is_none())
    }

    fn pending(&self) -> Pending {
        let all: Vec<u8> = self.bytes.iter().copied().collect();
        let head_len: usize =
            self.runs.iter().take_while(|run| run.offset.is_none()).map(|run| run.len).sum();
        Pending {
            confirmed: self.confirmed,
            received: self.received,
            head: all[..head_len.min(all.len())].to_vec(),
            all,
        }
    }
}

impl HolderSink {
    /// A sink whose next byte has offset `base`.
    pub(crate) fn new(base: u64) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(SinkState {
                received: base,
                confirmed: base,
                acked: base,
                snapshot_base: base,
                ..SinkState::default()
            }),
            changed: Condvar::new(),
            acker: OnceLock::new(),
        })
    }

    /// Acknowledge through `acker` from now on, starting with what the
    /// parser already parsed: the holder may be waiting for it.
    pub(crate) fn set_acker(&self, acker: Acker) {
        if self.acker.set(acker).is_err() {
            return;
        }
        let confirmed = {
            let mut state = self.state.lock().recover_poison();
            state.acked = state.acked.max(state.confirmed);
            state.confirmed
        };
        if let Some(acker) = self.acker.get() {
            acker(confirmed);
        }
    }

    /// Offset after the newest byte received.
    pub(crate) fn received(&self) -> u64 {
        self.state.lock().recover_poison().received
    }

    /// Offset after the last holder byte the parser finished parsing.
    pub(crate) fn confirmed(&self) -> u64 {
        self.state.lock().recover_poison().confirmed
    }

    /// The terminal ended or no holder streams it any more (set before
    /// [`Self::wait_end`] returns).
    pub(crate) fn has_ended(&self) -> bool {
        let state = self.state.lock().recover_poison();
        state.exit.is_some() || state.lost
    }

    /// The parser finished parsing every byte the reader took. The reader
    /// calls it right after it wrote them to the terminal, under the
    /// terminal lock, so whoever holds that lock sees a screen and a
    /// [`Self::pending`] that match exactly.
    pub(crate) fn confirm_parsed(&self) {
        self.state.lock().recover_poison().confirm();
    }

    /// Everything the parser has not finished parsing. Exact when called
    /// under the terminal lock (see [`Self::confirm_parsed`]): the screen is
    /// then the output up to [`Pending::confirmed`], and parsing
    /// [`Pending::all`] after it gives the screen at [`Pending::received`].
    pub(crate) fn pending(&self) -> Pending {
        self.state.lock().recover_poison().pending()
    }

    /// Bytes the parser reads before the holder's (an archived terminal's
    /// replay); they take no holder offset.
    pub(crate) fn prepend(&self, seed: &[u8]) {
        if seed.is_empty() {
            return;
        }
        let mut state = self.state.lock().recover_poison();
        // Before the reader takes anything: a seed is set at the spawn.
        debug_assert_eq!(state.in_flight, 0, "a seed after the reader started");
        for byte in seed.iter().rev() {
            state.bytes.push_front(*byte);
        }
        match state.runs.front_mut() {
            Some(Run { len, offset: None }) => *len += seed.len(),
            _ => state.runs.push_front(Run { len: seed.len(), offset: None }),
        }
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
        let mut state = self.state.lock().recover_poison();
        state.confirm();
        if state.has_unnumbered() || state.detached || state.lost || state.exit.is_some() {
            return None;
        }
        let since = state.confirmed.saturating_sub(state.snapshot_base);
        let idle = state.bytes.is_empty();
        ((idle && since >= SNAPSHOT_IDLE_BYTES) || since >= SNAPSHOT_EVERY_BYTES)
            .then_some(state.confirmed)
    }

    /// A snapshot at `base` went to the holder (or could not be made).
    pub(super) fn snapshot_taken(&self, base: u64) {
        let mut state = self.state.lock().recover_poison();
        state.snapshot_base = state.snapshot_base.max(base);
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
    /// detached) and every byte before was read. A call means the reader
    /// parsed what it took before (if [`Self::confirm_parsed`] did not say
    /// so already), so the acknowledgement for it goes out first.
    fn read(&self, buf: &mut [u8]) -> usize {
        let ack = {
            let mut state = self.state.lock().recover_poison();
            state.confirm();
            state.due_ack(self.acker.get().is_some())
        };
        if let (Some(offset), Some(acker)) = (ack, self.acker.get()) {
            acker(offset);
        }
        let mut state = self.state.lock().recover_poison();
        while state.bytes.is_empty() && state.exit.is_none() && !state.detached && !state.lost {
            state = self.changed.wait(state).recover_poison();
        }
        if state.detached {
            return 0;
        }
        // Taken, not parsed: the bytes stay queued (and in `pending`) until
        // the reader confirms them.
        let n = buf.len().min(state.bytes.len());
        let (head, tail) = state.bytes.as_slices();
        let from_head = n.min(head.len());
        buf[..from_head].copy_from_slice(&head[..from_head]);
        buf[from_head..n].copy_from_slice(&tail[..n - from_head]);
        state.in_flight = n;
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
            state.push_unnumbered(&[CANCEL]);
        }
        let skip = state.received.saturating_sub(offset) as usize;
        let from = offset.max(state.received);
        state.push_numbered(from, &bytes[skip.min(bytes.len())..]);
        state.received = end;
        drop(state);
        self.changed.notify_all();
    }

    fn gap(&self, requested: u64, oldest: u64) {
        let mut state = self.state.lock().recover_poison();
        if oldest > state.received {
            eprintln!("cmux-tui: holder terminal lost output {requested}..{oldest}");
            state.received = oldest;
            state.push_unnumbered(&[CANCEL]);
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
            // The prologue is the screen at `base`: once it is parsed, the
            // parser is at `base` (no holder byte before it comes).
            if state.runs.iter().all(|run| run.offset.is_none()) {
                state.confirmed = state.confirmed.max(base);
                state.acked = state.acked.max(base);
            }
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
    /// The terminal id (hex) its create's debug spans follow: the first
    /// output, first text and first prompt the daemon reads for it are
    /// marked as on the hosted path (new-terminal-100x's first-text).
    pub(super) terminal_id: String,
}

impl Read for SnapshottingReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if let Some(base) = self.sink.snapshot_due() {
            (self.snapshot)(base);
            self.sink.snapshot_taken(base);
        }
        let n = self.sink.read(buf);
        crate::debug_spans::output_marks(&self.terminal_id, &buf[..n]);
        Ok(n)
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
        assert_eq!(sink.confirmed(), 15);
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
    fn the_sink_acknowledges_what_the_parser_parsed_so_the_holder_sends_more() {
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
        // The last chunk is parsed once the reader says so.
        sink.confirm_parsed();
        sink.exit(ExitStatus::Exited(0), 2 * chunk.len() as u64);
        assert_eq!(reader.read(&mut buf).unwrap(), 0);
        let acks = acks.lock().unwrap().clone();
        let last = *acks.last().unwrap();
        // The seed takes no holder offset: what the parser parsed of the
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
        assert_eq!(sink.confirmed(), 21);
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
        SinkReader(sink).read_to_end(&mut out).unwrap();
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

    /// The replay race (holder item 1): a chunk the reader took but has not
    /// parsed is still pending, and the confirmed offset stays before it,
    /// so a hand-off to a new holder never claims a byte the screen does
    /// not show yet.
    #[test]
    fn a_taken_chunk_stays_pending_until_the_parser_confirms_it() {
        let sink = HolderSink::new(0);
        sink.prepend(b"seed");
        sink.data(0, b"\x1b[38;5;1");
        sink.data(8, b"96mRED");
        let mut buf = [0u8; 8];
        let mut reader = SinkReader(sink.clone());
        // The reader takes "seed\x1b[38" and is still parsing it.
        assert_eq!(reader.read(&mut buf).unwrap(), 8);
        let pending = sink.pending();
        assert_eq!((pending.confirmed, pending.received), (0, 14));
        assert_eq!(pending.head, b"seed");
        assert_eq!(pending.all, b"seed\x1b[38;5;196mRED");
        // Parsed: the confirmed offset moves past its holder bytes only.
        sink.confirm_parsed();
        let pending = sink.pending();
        assert_eq!((pending.confirmed, pending.received), (4, 14));
        assert!(pending.head.is_empty());
        assert_eq!(pending.all, b";5;196mRED");
    }
}
