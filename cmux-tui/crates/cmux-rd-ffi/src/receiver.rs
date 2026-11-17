//! The viewer side of one `cmux.rd/1` display stream, in safe Rust: bytes in,
//! complete frames, other messages and feedback datagrams out. The C ABI in
//! `lib.rs` is a thin shell over this type.

use std::collections::VecDeque;

use cmux_rd_core::reassembly::{CompleteFrame, Reassembler};
use cmux_rd_proto::{
    Arrival, DatagramHeader, DatagramKind, DecodeError, Feedback, HEADER_LEN, MAX_ARRIVALS, Nack,
    REF_NONE, STREAM_BULK, STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer, encode_stream_frame,
    flags,
};

/// How the session's datagrams travel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Carrier {
    /// Overlay datagrams: one call per datagram, feedback out as a bare datagram.
    Datagram,
    /// One reliable byte stream with `u8 type, u32 len` frames.
    Stream,
}

/// A message the viewer's transport handles itself (not a video shard).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    /// [`STREAM_CONTROL`] (JSON) or [`STREAM_DATAGRAM`] (a whole datagram).
    pub kind: u8,
    pub bytes: Vec<u8>,
}

/// Why a call was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReceiverError {
    /// The datagram is not valid `cmux.rd/1`.
    Invalid(DecodeError),
    /// The call does not match the receiver's carrier.
    Carrier,
    /// The stream framing broke or the peer outran the bounded queues; the
    /// receiver is unusable and the session must end.
    StreamFailed,
}

/// Feedback is sent at least this often while datagrams arrive (spec 6.1).
pub const FEEDBACK_INTERVAL_US: u64 = 50_000;
/// Feedback is sent at least this often while the session lives (keepalive).
pub const KEEPALIVE_US: u64 = 1_000_000;
/// The shortest time between two feedbacks that ask for a keyframe, or two
/// round trips when that is longer: the keyframe the first request gets
/// answers every request sent before it lands. On a path that holds every
/// datagram for 50-100 ms (Wi-Fi away from the access point), requests one
/// round trip apart turned each burst of late frames into another keyframe.
pub const MIN_RECOVERY_REQUEST_INTERVAL_US: u64 = 250_000;
/// Frames waiting for the caller. A keyframe replaces every older waiting
/// frame (newest wins); a reference chain longer than this means the caller
/// fell behind: the chain is dropped and a keyframe requested.
pub const MAX_READY_FRAMES: usize = 16;
/// Arrivals kept between feedback calls; older ones are dropped.
pub const MAX_PENDING_ARRIVALS: usize = 8 * MAX_ARRIVALS;
/// Bytes of queued messages before the receiver fails (a peer that floods).
pub const MAX_MESSAGE_BYTES: usize = 4 << 20;
/// What each queued message costs against [`MAX_MESSAGE_BYTES`] besides its
/// bytes, so a flood of empty messages is bounded too (64k messages at most).
pub const MESSAGE_OVERHEAD: usize = 64;
/// Decode times kept for the feedback median.
const DECODE_SAMPLES: usize = 30;

/// Viewer state for one display stream.
#[derive(Debug)]
pub struct Receiver {
    carrier: Carrier,
    /// The display stream this receiver reassembles; its feedback names it.
    stream: u16,
    reassembler: Reassembler,
    deframer: StreamDeframer,
    ready: VecDeque<CompleteFrame>,
    messages: VecDeque<Message>,
    message_bytes: usize,
    arrivals: VecDeque<Arrival>,
    decode_us: VecDeque<u32>,
    keyframe_requested: bool,
    /// The ready queue lost part of a reference chain: frames are dropped
    /// until a keyframe restarts the decoder.
    chain_broken: bool,
    /// The current recovery request already went out in a feedback; a new
    /// request goes out at once instead of on the feedback interval.
    recovery_sent: bool,
    /// When a feedback last asked for a keyframe.
    last_recovery_request_us: Option<u64>,
    released_since_feedback: bool,
    last_feedback_us: Option<u64>,
    frames_released: u64,
    frames_lost: u64,
    frames_skipped: u64,
    /// Frames ever put on the ready queue (the session tracks release order by it).
    frames_queued: u64,
    failed: bool,
}

/// Counters for the pane's status line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    pub acked_frame: u32,
    pub need_recovery: bool,
    pub frames_released: u64,
    pub frames_lost: u64,
    /// Decodable frames dropped from the ready queue because a newer
    /// keyframe made them unneeded (newest wins).
    pub frames_skipped: u64,
}

impl Receiver {
    /// `deadline_us`: the longest a frame may wait for missing shards; the
    /// wait itself is one round trip plus 10 ms after the frame's NACK
    /// (`Reassembler::repair_window_us`), with this as its ceiling.
    /// `nack_after_us`: how long a frame waits before its gaps are NACKed.
    pub fn new(carrier: Carrier, deadline_us: u64, nack_after_us: u64) -> Self {
        Self::for_stream(carrier, 0, deadline_us, nack_after_us)
    }

    /// A receiver for display stream `stream` (its feedback datagrams carry
    /// that stream, so the host recovers the right stream).
    pub fn for_stream(carrier: Carrier, stream: u16, deadline_us: u64, nack_after_us: u64) -> Self {
        Self {
            carrier,
            stream,
            reassembler: Reassembler::with_nack_after(deadline_us, nack_after_us),
            deframer: StreamDeframer::default(),
            ready: VecDeque::new(),
            messages: VecDeque::new(),
            message_bytes: 0,
            arrivals: VecDeque::new(),
            decode_us: VecDeque::new(),
            keyframe_requested: false,
            chain_broken: false,
            recovery_sent: false,
            last_recovery_request_us: None,
            released_since_feedback: false,
            last_feedback_us: None,
            frames_released: 0,
            frames_lost: 0,
            frames_skipped: 0,
            frames_queued: 0,
            failed: false,
        }
    }

    /// Adds one datagram (datagram carrier). Video and parity shards feed the
    /// reassembler; every other valid kind is queued as a [`Message`].
    pub fn push_datagram(&mut self, datagram: &[u8], now_us: u64) -> Result<(), ReceiverError> {
        if self.carrier != Carrier::Datagram {
            return Err(ReceiverError::Carrier);
        }
        self.check_alive()?;
        self.on_datagram(datagram, now_us)
    }

    /// Adds received stream bytes (stream carrier). Control frames are queued
    /// as messages; datagram frames are handled as by [`Self::push_datagram`],
    /// except that an invalid datagram inside the stream is skipped.
    pub fn push_stream(&mut self, bytes: &[u8], now_us: u64) -> Result<(), ReceiverError> {
        if self.carrier != Carrier::Stream {
            return Err(ReceiverError::Carrier);
        }
        self.check_alive()?;
        self.deframer.extend(bytes);
        loop {
            match self.deframer.next_frame() {
                Ok(None) => break,
                Ok(Some((STREAM_DATAGRAM, payload))) => {
                    // One bad datagram does not end a reliable stream.
                    let _ = self.on_datagram(&payload, now_us);
                }
                Ok(Some((kind, payload))) => self.queue_message(kind, payload)?,
                Err(_) => {
                    self.failed = true;
                    return Err(ReceiverError::StreamFailed);
                }
            }
            if self.failed {
                return Err(ReceiverError::StreamFailed);
            }
        }
        self.reassembler.tick(now_us).into_iter().for_each(|f| self.on_released(f));
        self.count_losses();
        Ok(())
    }

    /// Advances time with no new bytes: drops frames past their deadline.
    pub fn tick(&mut self, now_us: u64) {
        let released = self.reassembler.tick(now_us);
        released.into_iter().for_each(|f| self.on_released(f));
        self.count_losses();
    }

    /// The oldest frame ready to decode.
    pub fn pop_frame(&mut self) -> Option<CompleteFrame> {
        self.ready.pop_front()
    }

    /// Frames ready to decode.
    pub fn ready_frames(&self) -> usize {
        self.ready.len()
    }

    /// Frames ever put on the ready queue, dropped ones included.
    pub fn frames_queued(&self) -> u64 {
        self.frames_queued
    }

    /// The session's round trip (clock pings), which sizes how long a NACKed
    /// frame is waited for; `None` when unknown.
    pub fn set_path_rtt_us(&mut self, rtt_us: Option<u64>) {
        self.reassembler.set_path_rtt_us(rtt_us);
    }

    /// How long a NACKed frame is waited for before recovery is requested.
    pub fn repair_window_us(&self) -> u64 {
        self.reassembler.repair_window_us()
    }

    /// How long after a NACK an unanswered shard is requested again.
    pub fn retry_us(&self) -> u64 {
        self.reassembler.retry_us()
    }

    /// The oldest queued message.
    pub fn pop_message(&mut self) -> Option<Message> {
        let m = self.messages.pop_front()?;
        self.message_bytes = self.message_bytes.saturating_sub(m.bytes.len() + MESSAGE_OVERHEAD);
        Some(m)
    }

    /// Records one decode time for the feedback median.
    pub fn note_decode(&mut self, decode_us: u32) {
        if self.decode_us.len() >= DECODE_SAMPLES {
            self.decode_us.pop_front();
        }
        self.decode_us.push_back(decode_us);
    }

    /// Asks the host for a keyframe (a decode error or a frame gap). The
    /// request rides every feedback until a keyframe is released.
    pub fn request_keyframe(&mut self) {
        // A new request goes out in the next feedback, not on the interval.
        self.recovery_sent &= self.keyframe_requested;
        self.keyframe_requested = true;
    }

    /// Whether the next feedback asks the host to recover.
    pub fn need_recovery(&self) -> bool {
        self.keyframe_requested || self.chain_broken || self.reassembler.need_recovery()
    }

    /// A recovery request that no feedback carried yet: it goes out at once,
    /// so a given-up frame costs one round trip, not a feedback interval more.
    fn recovery_unsent(&self) -> bool {
        self.need_recovery() && !self.recovery_sent
    }

    /// How long after a keyframe request the next one may go out:
    /// [`MIN_RECOVERY_REQUEST_INTERVAL_US`], or two round trips if longer.
    pub fn recovery_request_interval_us(&self) -> u64 {
        self.reassembler
            .rtt_us()
            .map_or(0, |rtt| rtt.saturating_mul(2))
            .max(MIN_RECOVERY_REQUEST_INTERVAL_US)
    }

    /// When the next keyframe request may go out (0: now).
    fn recovery_allowed_at(&self) -> u64 {
        self.last_recovery_request_us
            .map_or(0, |at| at.saturating_add(self.recovery_request_interval_us()))
    }

    /// Whether a feedback sent at `now_us` asks for a keyframe.
    fn asks_recovery(&self, now_us: u64) -> bool {
        self.need_recovery() && now_us >= self.recovery_allowed_at()
    }

    /// Counters for the status line.
    pub fn stats(&self) -> Stats {
        Stats {
            acked_frame: self.reassembler.last_released(),
            need_recovery: self.need_recovery(),
            frames_released: self.frames_released,
            frames_lost: self.frames_lost,
            frames_skipped: self.frames_skipped,
        }
    }

    /// When the caller must call [`Self::tick`] or [`Self::feedback`] next:
    /// the earliest frame deadline or feedback time. `None` never happens
    /// while the session lives, because feedback doubles as keepalive.
    pub fn next_deadline_us(&self) -> u64 {
        // A failed receiver has nothing due: never ask for a timer.
        if self.failed {
            return u64::MAX;
        }
        let Some(last) = self.last_feedback_us else { return 0 };
        if self.released_since_feedback || self.arrivals.len() > MAX_ARRIVALS {
            return 0;
        }
        if self.recovery_unsent() {
            return self.recovery_allowed_at();
        }
        let mut deadline = last.saturating_add(KEEPALIVE_US);
        if !self.arrivals.is_empty() || self.need_recovery() {
            deadline = deadline.min(last.saturating_add(FEEDBACK_INTERVAL_US));
        }
        if let Some(expiry) = self.reassembler.next_expiry_us() {
            deadline = deadline.min(expiry);
        }
        if let Some(nack) = self.reassembler.next_nack_us() {
            deadline = deadline.min(nack);
        }
        deadline
    }

    /// The next feedback datagram if one is due at `now_us`, framed for the
    /// carrier. Call again until it returns `None`: more than
    /// [`MAX_ARRIVALS`] arrivals go out in several datagrams.
    pub fn feedback(&mut self, now_us: u64) -> Option<Vec<u8>> {
        if self.failed {
            return None;
        }
        let since = self.last_feedback_us.map(|last| now_us.saturating_sub(last));
        let due = since.is_none_or(|s| s >= FEEDBACK_INTERVAL_US);
        let keepalive = since.is_none_or(|s| s >= KEEPALIVE_US);
        let overflow = self.arrivals.len() > MAX_ARRIVALS;
        let nack_due = self.reassembler.next_nack_us().is_some_and(|deadline| now_us >= deadline);
        if !(self.released_since_feedback
            || keepalive
            || overflow
            || nack_due
            || (self.recovery_unsent() && now_us >= self.recovery_allowed_at())
            || (due && (!self.arrivals.is_empty() || self.need_recovery())))
        {
            return None;
        }
        let take = self.arrivals.len().min(MAX_ARRIVALS);
        let arrivals: Vec<Arrival> = self.arrivals.drain(..take).collect();
        let fb = if overflow {
            // Arrivals beyond one message go out first, without the rest.
            Feedback {
                acked_frame: self.reassembler.last_released(),
                arrivals,
                ..Feedback::default()
            }
        } else {
            self.last_feedback_us = Some(now_us);
            self.released_since_feedback = false;
            let need_recovery = self.asks_recovery(now_us);
            if need_recovery {
                self.recovery_sent = true;
                self.last_recovery_request_us = Some(now_us);
            }
            Feedback {
                acked_frame: self.reassembler.last_released(),
                decode_us: self.median_decode_us(),
                need_recovery,
                arrivals,
                nacks: self.nacks(now_us),
            }
        };
        Some(self.frame_datagram(&fb.encode()))
    }

    fn median_decode_us(&self) -> u32 {
        let mut sorted: Vec<u32> = self.decode_us.iter().copied().collect();
        sorted.sort_unstable();
        sorted.get(sorted.len() / 2).copied().unwrap_or(0)
    }

    fn nacks(&mut self, now_us: u64) -> Vec<Nack> {
        self.reassembler.take_nacks(now_us)
    }

    fn frame_datagram(&self, payload: &[u8]) -> Vec<u8> {
        let mut datagram = Vec::with_capacity(HEADER_LEN + payload.len());
        DatagramHeader {
            flags: 0,
            kind: DatagramKind::Feedback,
            stream: self.stream,
            frame: 0,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: 0,
        }
        .encode_into(&mut datagram);
        datagram.extend_from_slice(payload);
        match self.carrier {
            Carrier::Datagram => datagram,
            Carrier::Stream => {
                let mut out = Vec::new();
                // A feedback datagram is far below the stream frame limit.
                let _ = encode_stream_frame(STREAM_DATAGRAM, &datagram, &mut out);
                out
            }
        }
    }

    fn check_alive(&self) -> Result<(), ReceiverError> {
        if self.failed { Err(ReceiverError::StreamFailed) } else { Ok(()) }
    }

    fn on_datagram(&mut self, datagram: &[u8], now_us: u64) -> Result<(), ReceiverError> {
        let (header, payload) = DatagramHeader::decode(datagram).map_err(ReceiverError::Invalid)?;
        match header.kind {
            DatagramKind::Video | DatagramKind::Fec => {
                if self.arrivals.len() >= MAX_PENDING_ARRIVALS {
                    self.arrivals.pop_front();
                }
                // Viewer monotonic microseconds; the field wraps and only differences matter.
                self.arrivals.push_back(Arrival {
                    transport_seq: header.transport_seq,
                    arrival_us: now_us as u32,
                });
                let released = self.reassembler.push(&header, payload, now_us);
                released.into_iter().for_each(|f| self.on_released(f));
                self.count_losses();
                Ok(())
            }
            _ => {
                self.note_link_datagram(now_us);
                self.queue_message(STREAM_DATAGRAM, datagram.to_vec())
            }
        }
    }

    /// A datagram of any kind (another stream's, a clock pong) arrived on
    /// this stream's link at `now_us`: the link is not on hold.
    pub fn note_link_datagram(&mut self, now_us: u64) {
        self.reassembler.note_datagram(now_us);
    }

    fn queue_message(&mut self, kind: u8, bytes: Vec<u8>) -> Result<(), ReceiverError> {
        debug_assert!(matches!(kind, STREAM_CONTROL | STREAM_DATAGRAM | STREAM_BULK));
        let cost = bytes.len() + MESSAGE_OVERHEAD;
        if self.message_bytes + cost > MAX_MESSAGE_BYTES {
            self.failed = true;
            return Err(ReceiverError::StreamFailed);
        }
        self.message_bytes += cost;
        self.messages.push_back(Message { kind, bytes });
        Ok(())
    }

    /// Queues a released frame, newest wins. What may be dropped:
    /// - A keyframe (an IDR, which flushes every reference) needs no earlier
    ///   frame, so every frame still waiting is dropped and counted skipped.
    /// - A P-frame or a recovery frame needs its reference chain decoded in
    ///   order, so it never drops the frames before it. A recovery frame does
    ///   not drop either: frames between its reference and itself may be
    ///   long-term references the host predicts from later, and the host
    ///   counts them received (`acked_frame`).
    /// - A tile frame (rd change C3) tops off its own region only, so tiles
    ///   are never dropped for each other and never drop video frames.
    ///
    /// A chain longer than [`MAX_READY_FRAMES`] means the caller fell behind:
    /// the whole chain is dropped (decoding past a hole shows a corrupted
    /// picture), and so is every frame after it until a keyframe arrives.
    fn on_released(&mut self, frame: CompleteFrame) {
        self.released_since_feedback = true;
        self.frames_released += 1;
        let tile = frame.flags & flags::TILE != 0;
        let keyframe =
            !tile && (frame.flags & flags::KEYFRAME != 0 || frame.body.ref_frame == REF_NONE);
        if keyframe {
            self.keyframe_requested = false;
            self.chain_broken = false;
            self.frames_skipped += self.ready.len() as u64;
            self.ready.clear();
        } else if self.chain_broken {
            self.frames_lost += 1;
            return;
        } else if self.ready.len() >= MAX_READY_FRAMES {
            self.frames_lost += self.ready.len() as u64 + 1;
            self.ready.clear();
            self.chain_broken = !tile;
            self.keyframe_requested = true;
            return;
        }
        self.frames_queued += 1;
        self.ready.push_back(frame);
    }

    fn count_losses(&mut self) {
        self.frames_lost += self.reassembler.take_losses().len() as u64;
        // Recovered: the next request is new and goes out at once.
        if !self.need_recovery() {
            self.recovery_sent = false;
        }
    }
}
