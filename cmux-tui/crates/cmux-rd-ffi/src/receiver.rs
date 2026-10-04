//! The viewer side of one `cmux.rd/1` display stream, in safe Rust: bytes in,
//! complete frames, other messages and feedback datagrams out. The C ABI in
//! `lib.rs` is a thin shell over this type.

use std::collections::VecDeque;

use cmux_rd_core::reassembly::{CompleteFrame, Reassembler};
use cmux_rd_proto::{
    Arrival, DatagramHeader, DatagramKind, DecodeError, Feedback, HEADER_LEN, MAX_ARRIVALS,
    MAX_NACK_FRAMES, MAX_NACK_INDEXES, Nack, REF_NONE, STREAM_CONTROL, STREAM_DATAGRAM,
    StreamDeframer, encode_stream_frame, flags,
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
/// Frames waiting for the caller; older ones are dropped and recovery requested.
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
    nack_after_us: u64,
    reassembler: Reassembler,
    deframer: StreamDeframer,
    ready: VecDeque<CompleteFrame>,
    messages: VecDeque<Message>,
    message_bytes: usize,
    arrivals: VecDeque<Arrival>,
    decode_us: VecDeque<u32>,
    keyframe_requested: bool,
    released_since_feedback: bool,
    last_feedback_us: Option<u64>,
    frames_released: u64,
    frames_lost: u64,
    failed: bool,
}

/// Counters for the pane's status line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    pub acked_frame: u32,
    pub need_recovery: bool,
    pub frames_released: u64,
    pub frames_lost: u64,
}

impl Receiver {
    /// `deadline_us`: how long a frame may wait for missing shards.
    /// `nack_after_us`: how long a frame waits before its gaps are NACKed.
    pub fn new(carrier: Carrier, deadline_us: u64, nack_after_us: u64) -> Self {
        Self {
            carrier,
            nack_after_us,
            reassembler: Reassembler::new(deadline_us),
            deframer: StreamDeframer::default(),
            ready: VecDeque::new(),
            messages: VecDeque::new(),
            message_bytes: 0,
            arrivals: VecDeque::new(),
            decode_us: VecDeque::new(),
            keyframe_requested: false,
            released_since_feedback: false,
            last_feedback_us: None,
            frames_released: 0,
            frames_lost: 0,
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
        self.keyframe_requested = true;
    }

    /// Whether the next feedback asks the host to recover.
    pub fn need_recovery(&self) -> bool {
        self.keyframe_requested || self.reassembler.need_recovery()
    }

    /// Counters for the status line.
    pub fn stats(&self) -> Stats {
        Stats {
            acked_frame: self.reassembler.last_released(),
            need_recovery: self.need_recovery(),
            frames_released: self.frames_released,
            frames_lost: self.frames_lost,
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
        let mut deadline = last.saturating_add(KEEPALIVE_US);
        if !self.arrivals.is_empty() || self.need_recovery() {
            deadline = deadline.min(last.saturating_add(FEEDBACK_INTERVAL_US));
        }
        if let Some(expiry) = self.reassembler.next_expiry_us() {
            deadline = deadline.min(expiry);
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
        if !(self.released_since_feedback
            || keepalive
            || overflow
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
            Feedback {
                acked_frame: self.reassembler.last_released(),
                decode_us: self.median_decode_us(),
                need_recovery: self.need_recovery(),
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

    fn nacks(&self, now_us: u64) -> Vec<Nack> {
        self.reassembler
            .missing(now_us, self.nack_after_us)
            .into_iter()
            .take(MAX_NACK_FRAMES)
            .map(|(frame, indexes)| Nack {
                frame,
                indexes: indexes.into_iter().take(MAX_NACK_INDEXES).collect(),
            })
            .collect()
    }

    fn frame_datagram(&self, payload: &[u8]) -> Vec<u8> {
        let mut datagram = Vec::with_capacity(HEADER_LEN + payload.len());
        DatagramHeader {
            flags: 0,
            kind: DatagramKind::Feedback,
            stream: 0,
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
            _ => self.queue_message(STREAM_DATAGRAM, datagram.to_vec()),
        }
    }

    fn queue_message(&mut self, kind: u8, bytes: Vec<u8>) -> Result<(), ReceiverError> {
        debug_assert!(matches!(kind, STREAM_CONTROL | STREAM_DATAGRAM));
        let cost = bytes.len() + MESSAGE_OVERHEAD;
        if self.message_bytes + cost > MAX_MESSAGE_BYTES {
            self.failed = true;
            return Err(ReceiverError::StreamFailed);
        }
        self.message_bytes += cost;
        self.messages.push_back(Message { kind, bytes });
        Ok(())
    }

    fn on_released(&mut self, frame: CompleteFrame) {
        self.released_since_feedback = true;
        self.frames_released += 1;
        let keyframe = frame.flags & flags::KEYFRAME != 0 || frame.body.ref_frame == REF_NONE;
        if keyframe {
            self.keyframe_requested = false;
        }
        if self.ready.len() >= MAX_READY_FRAMES {
            // The caller fell behind. The dropped frame breaks the reference
            // chain, so the decoder must restart from a keyframe, unless the
            // new frame is one.
            self.ready.pop_front();
            self.frames_lost += 1;
            self.keyframe_requested |= !keyframe;
        }
        self.ready.push_back(frame);
    }

    fn count_losses(&mut self) {
        self.frames_lost += self.reassembler.take_losses().len() as u64;
    }
}
