//! One holder terminal's output queue on the daemon side.

use std::collections::{BTreeSet, VecDeque};
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
    /// Offsets where a holder died inside a PTY read that started there:
    /// the bytes it took are lost, and the output from each on does not
    /// follow the output before ([`HolderSink::cut_at`]). Only offsets the
    /// sink has not received up to yet (two holders can die before it
    /// catches up).
    cuts: BTreeSet<u64>,
    /// The newest cut whose CAN was queued, until a screen snapshot at or
    /// past it reached the holder: a restarted daemon replays the holder's
    /// ring from its prologue, and a ring replay across the cut would
    /// splice the bytes before and after it, so the prologue must move past
    /// it ([`HolderSink::snapshot_due`]).
    cut_unsnapshotted: Option<u64>,
    /// Where output is lost if the holder an ADOPT went to continues the
    /// dead holder's segment, and where if it starts a fresh ring instead:
    /// its ADOPTED answer says which ([`HolderSink::expect_adoption`]).
    adoption: Option<AdoptionCuts>,
}

/// The possible losses of one adoption sent to a holder that answers it
/// with ADOPTED ([`HolderSink::expect_adoption`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct AdoptionCuts {
    /// Where the adopted stream continues (the newest byte received).
    pub(super) resume: u64,
    /// The end of the dead holder's segment the ADOPT handed on, if it
    /// handed one: an answered ring that ends there (or past it) is that
    /// segment, continued.
    pub(super) handed_end: Option<u64>,
    /// The cut when the holder continues the handed segment: a read the
    /// dead holder died inside, at the segment's end.
    pub(super) continued: Option<u64>,
    /// The cut when the holder writes a fresh ring from `resume` instead of
    /// the handed segment: everything the dead holder read past it is lost
    /// too. `None` when nothing is lost then, or when it was marked already
    /// (the ADOPT handed no segment of the dead holder's).
    pub(super) fresh: Option<u64>,
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

    /// A pending cut at the next byte to receive: queue its CAN now. One
    /// the stream already passed (a gap or a prologue moved past it) was
    /// cancelled by them.
    fn take_cut_at_received(&mut self) {
        loop {
            let Some(cut) = self.cuts.first().copied().filter(|cut| *cut <= self.received) else {
                return;
            };
            self.cuts.remove(&cut);
            if cut == self.received {
                eprintln!("cmux-tui: holder terminal lost output at {cut} (holder died reading)");
                self.push_unnumbered(&[CANCEL]);
                self.cut_unsnapshotted = Some(cut);
            }
        }
    }

    /// [`HolderSink::cut_at`] under the lock.
    fn cut(&mut self, at: u64) {
        if at < self.received {
            return;
        }
        self.cuts.insert(at);
        self.take_cut_at_received();
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
            head: all.get(..head_len).unwrap_or(&all).to_vec(),
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
    /// screen at any offset until they are parsed. Due at once, too, when
    /// the parser passed a cut ([`Self::cut_at`]) no snapshot is past yet:
    /// the holder's prologue must not leave the cut in the ring a restarted
    /// daemon replays.
    pub(super) fn snapshot_due(&self) -> Option<u64> {
        let mut state = self.state.lock().recover_poison();
        state.confirm();
        if state.has_unnumbered() || state.detached || state.lost || state.exit.is_some() {
            return None;
        }
        let since = state.confirmed.saturating_sub(state.snapshot_base);
        let idle = state.bytes.is_empty();
        let past_cut = state.cut_unsnapshotted.is_some_and(|cut| state.confirmed >= cut);
        ((idle && since >= SNAPSHOT_IDLE_BYTES) || since >= SNAPSHOT_EVERY_BYTES || past_cut)
            .then_some(state.confirmed)
    }

    /// A snapshot at `base` was handled: `reached` when it went to the
    /// holder or cannot be made (an empty replay), false when no holder
    /// link was open. Either way the next periodic one waits for more
    /// output; only a reached one moves the holder's prologue past a cut,
    /// so a cut's snapshot is due again until a holder link takes it.
    pub(super) fn snapshot_taken(&self, base: u64, reached: bool) {
        let mut state = self.state.lock().recover_poison();
        state.snapshot_base = state.snapshot_base.max(base);
        if reached && state.cut_unsnapshotted.is_some_and(|cut| base >= cut) {
            state.cut_unsnapshotted = None;
        }
    }

    /// Output was lost at holder offset `at` (a holder died inside a PTY
    /// read that started there, `cmux_holder::ring::interrupted_read`, or
    /// an adoption dropped the bytes from `at` on): the bytes the stream
    /// brings from `at` do not continue the ones before. The parser gets a
    /// CAN right before the byte at `at` (now, when every byte before it
    /// was received), so it does not continue an escape sequence or a
    /// UTF-8 character the loss cut, and the loss is logged. Never a silent
    /// splice. An offset before what the sink received is ignored: no holder
    /// can have sent a byte past a read it never published.
    pub(crate) fn cut_at(&self, at: u64) {
        self.state.lock().recover_poison().cut(at);
        self.changed.notify_all();
    }

    /// An ADOPT goes to a holder that answers it with ADOPTED. When it
    /// hands the dead holder's ring segment on, the new holder may continue
    /// it or, when it cannot (a segment it refuses), start a fresh ring at
    /// the resume offset. Which loss to mark depends on that: `continued`
    /// when it continues the segment, `fresh` when it does not. Its ADOPTED
    /// answer decides ([`TerminalSink::adopted`], before any output of the
    /// adopted stream); a cut chosen before the answer would be wrong for
    /// one of the two (a silent splice at the resume offset, and a false
    /// CAN inside valid output at the segment's end).
    pub(super) fn expect_adoption(&self, cuts: AdoptionCuts) {
        self.state.lock().recover_poison().adoption = Some(cuts);
    }

    /// The plan of [`Self::expect_adoption`] names no loss: its ADOPT never
    /// reached the holder whole (nothing continues the segment, which stays
    /// the custody copy and is planned again with the next adoption), or
    /// the holder it went to still runs the terminal after a reconnect and
    /// resumes it from its own ring.
    pub(super) fn forget_adoption(&self) {
        self.state.lock().recover_poison().adoption = None;
    }

    /// Before a new adoption: an earlier one whose answer never came (the
    /// link ended first, or the holder refused it) leaves the daemon no
    /// custody segment, so nobody can say what that holder read from the
    /// PTY before it went away: the next holder starts at the resume
    /// offset, and the stream is cut there.
    pub(super) fn settle_unanswered_adoption(&self) {
        let mut state = self.state.lock().recover_poison();
        if let Some(cuts) = state.adoption.take() {
            state.cut(cuts.resume);
            drop(state);
            self.changed.notify_all();
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
    /// detached) and every byte before was read. A call means the reader
    /// parsed what it took before (if [`Self::confirm_parsed`] did not say
    /// so already), so the acknowledgement for it goes out first. Also
    /// returns how many of the bytes, from the first, take no holder offset
    /// (a reopen seed, a prologue): they are not the shell's output.
    fn read(&self, buf: &mut [u8]) -> (usize, usize) {
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
            return (0, 0);
        }
        // Taken, not parsed: the bytes stay queued (and in `pending`) until
        // the reader confirms them.
        let (head, tail) = state.bytes.as_slices();
        let mut n = 0;
        for part in [head, tail] {
            let Some(room) = buf.get_mut(n..) else { break };
            let take = room.len().min(part.len());
            if let (Some(to), Some(from)) = (room.get_mut(..take), part.get(..take)) {
                to.copy_from_slice(from);
            }
            n += take;
        }
        state.in_flight = n;
        let unnumbered: usize =
            state.runs.iter().take_while(|run| run.offset.is_none()).map(|run| run.len).sum();
        (n, unnumbered.min(n))
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
        let mut from = offset.max(state.received);
        let mut rest = bytes.get(skip..).unwrap_or_default();
        loop {
            let inside = state.cuts.iter().copied().find(|cut| *cut > from && *cut < end);
            let Some(cut) = inside else { break };
            // A dead holder's lost read sits inside these bytes: the parser
            // gets its CAN between the bytes before it and the ones after.
            let (before, after) = rest.split_at((cut - from) as usize);
            state.push_numbered(from, before);
            state.received = cut;
            state.take_cut_at_received();
            (from, rest) = (cut, after);
        }
        state.push_numbered(from, rest);
        state.received = end;
        state.take_cut_at_received();
        drop(state);
        self.changed.notify_all();
    }

    fn gap(&self, requested: u64, oldest: u64) {
        let mut state = self.state.lock().recover_poison();
        if oldest > state.received {
            eprintln!("cmux-tui: holder terminal lost output {requested}..{oldest}");
            state.received = oldest;
            state.push_unnumbered(&[CANCEL]);
            // A cut inside the gap or at its end: the gap's CAN covers it.
            state.cuts.retain(|cut| *cut > oldest);
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
            // A cut at `base` follows the screen; one before it is in the
            // prologue's past.
            state.take_cut_at_received();
        }
        state.snapshot_base = state.snapshot_base.max(base);
        drop(state);
        self.changed.notify_all();
    }

    fn acks_itself(&self) -> bool {
        true
    }

    fn adopted(&self, end: u64) {
        let mut state = self.state.lock().recover_poison();
        let Some(cuts) = state.adoption.take() else { return };
        let continued = cuts.handed_end.is_some_and(|handed| end >= handed);
        if let Some(at) = if continued { cuts.continued } else { cuts.fresh } {
            state.cut(at);
            drop(state);
            self.changed.notify_all();
        }
    }

    fn refused(&self, message: &str) {
        // No holder streams it: the reader drains and the wait ends lost.
        eprintln!("cmux-tui: the terminal holder refused a terminal's stream: {message}");
        self.lose();
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
        Ok(self.0.read(buf).0)
    }
}

/// [`SinkReader`] for a terminal on the holder: before each read, while
/// the parser has parsed every byte it was handed, it hands the holder a
/// due screen snapshot ([`HolderSink::snapshot_due`]), so a restarted
/// daemon restores modes, alternate screen, title and directory however
/// much the terminal printed since they were set.
pub(super) struct SnapshottingReader {
    pub(super) sink: Arc<HolderSink>,
    /// Builds and sends the snapshot at an offset (the terminal's replay):
    /// false when no holder link was open to take it.
    pub(super) snapshot: Box<dyn Fn(u64) -> bool + Send>,
    /// The terminal id (hex) its create's debug spans follow: the first
    /// output, first text and first prompt the shell printed are marked as
    /// on the hosted path (new-terminal-100x's first-text). Only holder
    /// output counts: a reopened terminal's replayed seed or a prologue is
    /// not the shell's first text.
    pub(super) terminal_id: String,
}

impl Read for SnapshottingReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if let Some(base) = self.sink.snapshot_due() {
            let reached = (self.snapshot)(base);
            self.sink.snapshot_taken(base, reached);
        }
        let (n, unnumbered) = self.sink.read(buf);
        if n > unnumbered {
            if let Some(output) = buf.get(unnumbered..n) {
                crate::debug_spans::output_marks(&self.terminal_id, output);
            }
            cmux_flow_trace::hop("daemon.output.holder", 0, &self.terminal_id);
        }
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

    /// Review 1 of pl-holder-11: a holder killed inside a PTY read lost
    /// the bytes that read took, however many. The dead holder's segment
    /// names the offset ([`HolderSink::cut_at`]), and the parser gets a CAN
    /// exactly there: inside a later chunk, between its bytes before and
    /// after the cut, and at once when every byte before it was received.
    /// A cut behind what was received names nothing.
    #[test]
    fn output_lost_where_a_holder_died_reading_is_cancelled_not_spliced() {
        let sink = HolderSink::new(0);
        sink.data(0, b"\x1b[3");
        sink.cut_at(5);
        sink.cut_at(1);
        sink.data(3, b"8;5;1");
        sink.cut_at(8);
        sink.data(8, b"x");
        sink.exit(ExitStatus::Exited(0), 9);
        let mut out = Vec::new();
        SinkReader(sink.clone()).read_to_end(&mut out).unwrap();
        assert_eq!(out, b"\x1b[38;\x185;1\x18x");
        assert_eq!((sink.received(), sink.confirmed()), (9, 9));
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
        sink.snapshot_taken(burst.len() as u64, true);
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

    /// A reopened terminal's seed (and a prologue) is not the shell's
    /// output: a read says how many of its bytes come before the first
    /// holder byte, so first-output marks skip them.
    #[test]
    fn a_read_says_how_many_leading_bytes_are_not_holder_output() {
        let sink = HolderSink::new(0);
        sink.prepend(b"replayed screen");
        sink.data(0, b"$ ");
        let mut buf = [0u8; 8];
        assert_eq!(sink.read(&mut buf), (8, 8), "the seed's first bytes");
        let mut buf = [0u8; 64];
        assert_eq!(sink.read(&mut buf), (9, 7), "the seed's rest, then the shell's prompt");
        assert_eq!(&buf[7..9], b"$ ");
        sink.data(2, b"ls");
        assert_eq!(sink.read(&mut buf), (2, 0), "only the shell's output");
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
